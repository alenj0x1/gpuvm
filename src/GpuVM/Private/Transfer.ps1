# Files into a running VM, from this PC or from another VM (lab 043). Everything goes as one tar stream over
# PowerShell Direct: GpuVM writes the archive itself (pax headers, names it checked) from the files it chose, and the
# guest's own tar.exe unpacks it into a hidden folder that is moved into place at the end. One round trip per 4 MB
# instead of per file (2000 small files: a few seconds instead of a minute), nothing is written to this PC's disk, and
# the VM never reads anything of this PC: it only receives bytes.

$script:TransferChunk = 4MB
# Files from this size up don't go in the stream: several PowerShell Direct sessions write parts of each at once.
# One session tops out near 10 MB/s; 2, 4 and 8 reached ~20, ~32 and ~42 MB/s (lab 043, parallel.ps1), with no new
# channel into the VM.
$script:TransferDirectMin = 16MB
$script:TransferLanes = 8
# Names and counts a guest (the source of a VM -> VM copy) may report: anything else stops the copy.
$script:TransferMaxEntries = 200000
$script:TransferMaxName = 1024

function Get-TransferMarker {
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{8,32}$')][string]$Id)
    Join-Path (Get-DataPath 'transfers') "$Id.cancel"
}

# A path of this PC that may be sent to a VM: a plain file or folder (not a link), never GpuVM's own data (VM disks,
# saved passwords), Windows, or a folder that contains them (a drive, Users). The service has already opened it as
# the user (unelevated), so it is something the user can read.
function Assert-SendablePath {
    param([Parameter(Mandatory)][string]$Path)
    # A full path as given (a relative one would be resolved against this process's folder, not checked by the service).
    if ($Path -notmatch '^[A-Za-z]:\\.' -or $Path -match '\\\.\.?(\\|$)') { throw "$Path no es un archivo o carpeta de un disco de este equipo." }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if (-not $item) { throw "No existe $full." }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$full es un enlace; elige la ubicación real." }
    if ($item -is [IO.DirectoryInfo]) { Assert-ImportableFolder -Path $full; return }
    foreach ($protected in @((Get-GpuVMDefaultRoot), $script:DataRoot, $env:SystemRoot) | Where-Object { $_ }) {
        $p = [IO.Path]::GetFullPath($protected).TrimEnd('\')
        if ("$full\".StartsWith("$p\", [StringComparison]::OrdinalIgnoreCase)) { throw "No se puede enviar ${full}: está dentro de $p." }
    }
}

# A name that came from a guest, as a relative path inside the copy: no drive, no "..", no stream (":"), no control
# or reserved characters. A guest that sends anything else is trying to write outside the folder of the other VM.
function Assert-TransferName {
    param([AllowEmptyString()][string]$Name)
    if (-not $Name -or $Name.Length -gt $script:TransferMaxName) { throw 'Un nombre de archivo no es válido; no se copia.' }
    foreach ($part in $Name.Split('\')) {
        if (-not $part -or $part -eq '.' -or $part -eq '..' -or $part.Length -gt 255 -or $part -match '[\x00-\x1f<>:"/|?*]' -or $part -match '[ .]$') {
            throw "El nombre $Name no es válido; no se copia."
        }
    }
}

# What will be sent from this PC: every file and folder under the chosen paths, links skipped (never followed), with
# names relative to each chosen item's parent. Two chosen items with the same name get " (2)".
function Get-HostTransferEntries {
    param([Parameter(Mandatory)][string[]]$Path)
    $entries = [System.Collections.Generic.List[object]]::new()
    $tops = @{}
    $skipped = 0
    foreach ($p in $Path) {
        Assert-SendablePath -Path $p
        $full = [IO.Path]::GetFullPath($p).TrimEnd('\')
        $item = Get-Item -LiteralPath $full -Force
        $top = Get-UniqueName -Name $item.Name -Taken $tops
        $tops[$top] = $true
        if ($item -is [IO.FileInfo]) { $entries.Add([pscustomobject]@{ Rel = $top; Full = $full; Size = $item.Length; Dir = $false }); continue }
        $entries.Add([pscustomobject]@{ Rel = $top; Full = $full; Size = 0; Dir = $true })
        $pending = [System.Collections.Generic.Stack[object]]::new()
        $pending.Push(@($full, $top))
        while ($pending.Count) {
            $dir, $rel = $pending.Pop()
            try { $children = [IO.DirectoryInfo]::new($dir).GetFileSystemInfos() }
            catch { throw "No se pudo leer $dir; no se envía nada." }
            foreach ($child in $children) {
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { $skipped++; continue }
                $childRel = "$rel\$($child.Name)"
                if ($child -is [IO.DirectoryInfo]) {
                    $entries.Add([pscustomobject]@{ Rel = $childRel; Full = $child.FullName; Size = 0; Dir = $true })
                    $pending.Push(@($child.FullName, $childRel))
                }
                else { $entries.Add([pscustomobject]@{ Rel = $childRel; Full = $child.FullName; Size = $child.Length; Dir = $false }) }
            }
        }
    }
    [pscustomobject]@{ Entries = $entries; Skipped = $skipped }
}

function Get-UniqueName {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][hashtable]$Taken)
    if (-not $Taken.ContainsKey($Name)) { return $Name }
    $base = [IO.Path]::GetFileNameWithoutExtension($Name)
    $ext = [IO.Path]::GetExtension($Name)
    for ($i = 2; ; $i++) { $candidate = "$base ($i)$ext"; if (-not $Taken.ContainsKey($candidate)) { return $candidate } }
}

# ---------------------------------------------------------------- tar (POSIX pax)

# The 512-byte headers of one entry: a pax record with its real name (UTF-8, any length) and the ustar header.
function New-TarHeader {
    param([Parameter(Mandatory)][string]$Name, [int64]$Size = 0, [switch]$Directory, [datetime]$Modified = [datetime]::UtcNow)
    $tarName = $Name.Replace('\', '/') + $(if ($Directory) { '/' } else { '' })
    $record = "path=$tarName`n"
    $body = [Text.Encoding]::UTF8.GetByteCount($record)
    # The record starts with its own length in decimal, counting the digits themselves.
    $length = $body + 1
    while ("$length".Length + 1 + $body -ne $length) { $length = "$length".Length + 1 + $body }
    $pax = [Text.Encoding]::UTF8.GetBytes("$length $record")
    $paxBlocks = [math]::Ceiling($pax.Length / 512)
    $out = [byte[]]::new(512 + $paxBlocks * 512 + 512)
    Write-UstarHeader -Buffer $out -Offset 0 -Name 'PaxHeader' -Size $pax.Length -Type ([byte][char]'x') -Modified $Modified
    [Array]::Copy($pax, 0, $out, 512, $pax.Length)
    $ascii = ($tarName -replace '[^\x20-\x7e]', '_')
    if ($ascii.Length -gt 99) { $ascii = $ascii.Substring($ascii.Length - 99) }
    Write-UstarHeader -Buffer $out -Offset (512 + $paxBlocks * 512) -Name $ascii -Size $(if ($Directory) { 0 } else { $Size }) -Type $(if ($Directory) { [byte][char]'5' } else { [byte][char]'0' }) -Modified $Modified
    $out
}

function Write-UstarHeader {
    param([byte[]]$Buffer, [int]$Offset, [string]$Name, [int64]$Size, [byte]$Type, [datetime]$Modified)
    $put = { param($at, $text) $b = [Text.Encoding]::ASCII.GetBytes($text); [Array]::Copy($b, 0, $Buffer, $Offset + $at, $b.Length) }
    & $put 0 $Name
    & $put 100 ('{0}' -f [Convert]::ToString($(if ($Type -eq [byte][char]'5') { 493 } else { 420 }), 8).PadLeft(7, '0'))
    & $put 108 '0000000'
    & $put 116 '0000000'
    & $put 124 ([Convert]::ToString($Size, 8).PadLeft(11, '0'))
    $epoch = [int64]([datetimeoffset]$Modified.ToUniversalTime()).ToUnixTimeSeconds()
    & $put 136 ([Convert]::ToString([math]::Max(0, $epoch), 8).PadLeft(11, '0'))
    $Buffer[$Offset + 156] = $Type
    & $put 257 "ustar`0"
    & $put 263 '00'
    # Checksum: the sum of the header's bytes with its own field as spaces.
    for ($i = 148; $i -lt 156; $i++) { $Buffer[$Offset + $i] = 32 }
    $sum = 0
    for ($i = 0; $i -lt 512; $i++) { $sum += $Buffer[$Offset + $i] }
    & $put 148 ([Convert]::ToString($sum, 8).PadLeft(6, '0') + "`0 ")
}

# ---------------------------------------------------------------- the receiving side, in the guest

# Starts tar in the guest, reading the stream into a hidden folder inside Desktop\<Folder> of the user signed in at
# the VM's screen (or of the session's user if nobody is). Returns the folder and the free space there.
function Open-GuestReceiver {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Folder)
    $answer = Invoke-Command -Session $Session -ErrorAction Stop -ArgumentList $Id, $Folder -ScriptBlock {
        param($id, $folder)
        $desktop = $null
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        if ($user) {
            try {
                $sid = ([Security.Principal.NTAccount]$user).Translate([Security.Principal.SecurityIdentifier]).Value
                $profile = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid").ProfileImagePath
                $shell = (Get-ItemProperty "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction SilentlyContinue).Desktop
                $desktop = if ($shell) { $shell -replace '%USERPROFILE%', $profile } else { Join-Path $profile 'Desktop' }
            }
            catch { $desktop = $null }
        }
        if (-not $desktop) { $desktop = [Environment]::GetFolderPath('Desktop') }
        $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
        if (-not (Test-Path $tar)) { return @{ error = 'Windows en la máquina no tiene tar.exe (hace falta Windows 10 1803 o posterior).' } }
        $dest = Join-Path $desktop $folder
        $staging = Join-Path $dest ".gpuvm-$id"
        New-Item -ItemType Directory -Force -Path $staging | Out-Null
        (Get-Item -LiteralPath $staging -Force).Attributes = 'Hidden, Directory'
        $psi = [Diagnostics.ProcessStartInfo]::new($tar, "-x -f - -C `"$staging`"")
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardError = $true
        if (-not (Test-Path variable:global:GpuVMReceive)) { $global:GpuVMReceive = @{} }
        $process = [Diagnostics.Process]::Start($psi)
        $global:GpuVMReceive[$id] = @{ process = $process; dest = $dest; staging = $staging; error = $process.StandardError.ReadToEndAsync() }
        $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($dest))
        @{ dest = $dest; staging = $staging; free = [int64]$drive.AvailableFreeSpace }
    }
    $answer = @($answer)[-1]
    if ($answer['error']) { throw (ConvertTo-GuestString $answer['error']) }
    [pscustomobject]@{ Dest = ConvertTo-GuestString $answer['dest'] -MaxLength 400; Staging = ConvertTo-GuestString $answer['staging'] -MaxLength 460; Free = [int64]$answer['free'] }
}

function Send-GuestBytes {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][byte[]]$Bytes)
    Invoke-Command -Session $Session -ErrorAction Stop -ArgumentList $Id, $Bytes -ScriptBlock {
        param($id, [byte[]]$b)
        $global:GpuVMReceive[$id].process.StandardInput.BaseStream.Write($b, 0, $b.Length)
    }
}

# Ends the stream. Done: each item moves from the hidden folder into Desktop\<Folder> (a name already there gets
# " (2)"), and the names it got come back. Cancelled or failed: tar is stopped and the hidden folder deleted.
function Close-GuestReceiver {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Id, [switch]$Cancel)
    $answer = Invoke-Command -Session $Session -ErrorAction Stop -ArgumentList @($Id, $Cancel.IsPresent) -ScriptBlock {
        param($id, $cancel)
        $r = $global:GpuVMReceive[$id]
        if (-not $r) { return @{ ok = $false; error = 'sin recepción' } }
        $global:GpuVMReceive.Remove($id)
        $p = $r.process
        try { $p.StandardInput.Close() } catch { }
        if ($cancel) { try { $p.Kill() } catch { } }
        $null = $p.WaitForExit(60000)
        $ok = -not $cancel -and $p.HasExited -and $p.ExitCode -eq 0
        $names = @()
        if ($ok) {
            foreach ($item in Get-ChildItem -LiteralPath $r.staging -Force) {
                $name = $item.Name
                $base = [IO.Path]::GetFileNameWithoutExtension($name); $ext = if ($item.PSIsContainer) { '' } else { [IO.Path]::GetExtension($name) }
                if ($item.PSIsContainer) { $base = $name }
                for ($i = 2; Test-Path -LiteralPath (Join-Path $r.dest $name); $i++) { $name = "$base ($i)$ext" }
                Move-Item -LiteralPath $item.FullName -Destination (Join-Path $r.dest $name)
                $names += $name
            }
        }
        Remove-Item -LiteralPath $r.staging -Recurse -Force -ErrorAction SilentlyContinue
        $err = if ($ok -or $cancel) { '' } else { "tar $(if ($p.HasExited) { $p.ExitCode } else { 'sigue abierto' }): $("$($r.error.Result)".Trim())" }
        @{ ok = $ok; names = $names; error = $err }
    }
    $answer = @($answer)[-1]
    [pscustomobject]@{
        Ok    = [bool]$answer['ok']
        Names = @($answer['names'] | ForEach-Object { ConvertTo-GuestString $_ -MaxLength 260 })
        Error = ConvertTo-GuestString $answer['error'] -MaxLength 300
    }
}

# ---------------------------------------------------------------- the sending side

# Collects bytes into 4 MB chunks and sends each full chunk; checks for a cancel and reports progress (at most
# twice a second) as it goes.
function New-TransferPipe {
    param($Session, [string]$Id, [int64]$Total, [string]$Marker)
    @{ Session = $Session; Id = $Id; Buffer = [byte[]]::new($script:TransferChunk); Fill = 0; Sent = [int64]0
       Total = [math]::Max([int64]1, $Total); Marker = $Marker; Next = [datetime]::MinValue }
}

function Write-TransferBytes {
    param([hashtable]$Pipe, [byte[]]$Bytes, [int]$Offset = 0, [int]$Count = $Bytes.Length)
    while ($Count -gt 0) {
        $n = [math]::Min($Count, $Pipe.Buffer.Length - $Pipe.Fill)
        [Array]::Copy($Bytes, $Offset, $Pipe.Buffer, $Pipe.Fill, $n)
        $Pipe.Fill += $n; $Offset += $n; $Count -= $n
        if ($Pipe.Fill -eq $Pipe.Buffer.Length) { Send-TransferChunk -Pipe $Pipe }
    }
}

function Send-TransferChunk {
    param([hashtable]$Pipe)
    if ($Pipe.Fill -eq 0) { return }
    if (Test-Path -LiteralPath $Pipe.Marker) { throw [OperationCanceledException]::new('Envío cancelado.') }
    # Assigned in each branch: "$x = if (...) { $array }" unrolls the array into loose objects (4 million of them).
    if ($Pipe.Fill -eq $Pipe.Buffer.Length) { $piece = $Pipe.Buffer } else { $piece = [byte[]]::new($Pipe.Fill); [Array]::Copy($Pipe.Buffer, $piece, $Pipe.Fill) }
    Send-GuestBytes -Session $Pipe.Session -Id $Pipe.Id -Bytes $piece
    $Pipe.Fill = 0
    $Pipe.Sent += $piece.Length
    if ([datetime]::UtcNow -ge $Pipe.Next) {
        $Pipe.Next = [datetime]::UtcNow.AddMilliseconds(500)
        Write-TransferProgress -Percent ([math]::Min(99, [math]::Floor(100 * $Pipe.Sent / $Pipe.Total))) -Sent $Pipe.Sent -Total $Pipe.Total
    }
}
function Write-TransferProgress {
    param([int]$Percent, [int64]$Sent, [int64]$Total)
    # The stream also carries tar headers and padding: never more than the files themselves.
    $Sent = [math]::Min($Sent, $Total)
    $unit = if ($Total -ge 1GB) { 1GB, 'GB' } else { 1MB, 'MB' }
    $fmt = { param($n) [math]::Round($n / $unit[0], 1).ToString([cultureinfo]::InvariantCulture) }
    Write-Step "Enviando $Percent % · $(& $fmt $Sent) de $(& $fmt $Total) $($unit[1])"
}

# ---------------------------------------------------------------- sessions and the source VM

# A PowerShell Direct session to a running VM with its saved Windows password.
function Open-TransferSession {
    param([Parameter(Mandatory)][string]$Name)
    $state = Get-GpuVMState -Name $Name
    $guest = Get-GpuVMGuestCredential -State $state
    if (-not $guest) { throw "Guarda la contraseña de Windows de '$Name' para pasarle archivos." }
    if ((Get-VM -Name $Name).State -ne 'Running') { throw "La VM '$Name' está apagada." }
    New-PSSession -VMName $Name -Credential $guest -ErrorAction Stop
}

# What the source VM has under the chosen paths. The VM answers, so every name and size is checked here: names stay
# relative and inside the copy (Assert-TransferName), sizes are whole numbers, and the list has a limit.
function Get-GuestTransferEntries {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string[]]$Path)
    $raw = Invoke-Command -Session $Session -ErrorAction Stop -ArgumentList (, $Path) -ScriptBlock {
        param([string[]]$paths)
        $out = [System.Collections.Generic.List[object]]::new()
        $skipped = 0
        foreach ($p in $paths) {
            $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            if (-not $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $skipped++; continue }
            if (-not $item.PSIsContainer) { $out.Add(@{ rel = $item.Name; full = $item.FullName; size = $item.Length; dir = $false }); continue }
            $out.Add(@{ rel = $item.Name; full = $item.FullName; size = 0; dir = $true })
            $pending = [System.Collections.Generic.Stack[object]]::new()
            $pending.Push(@($item.FullName, $item.Name))
            while ($pending.Count) {
                $dir, $rel = $pending.Pop()
                foreach ($child in [IO.DirectoryInfo]::new($dir).GetFileSystemInfos()) {
                    if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { $skipped++; continue }
                    $isDir = $child -is [IO.DirectoryInfo]
                    $out.Add(@{ rel = "$rel\$($child.Name)"; full = $child.FullName; size = $(if ($isDir) { 0 } else { $child.Length }); dir = $isDir })
                    if ($isDir) { $pending.Push(@($child.FullName, "$rel\$($child.Name)")) }
                }
            }
        }
        @{ entries = $out.ToArray(); skipped = $skipped }
    }
    $raw = @($raw)[-1]
    $list = @($raw['entries'])
    if ($list.Count -gt $script:TransferMaxEntries) { throw "Son más de $($script:TransferMaxEntries) archivos; elige menos." }
    if (-not $list.Count) { throw 'No se encontró nada para enviar en esa máquina.' }
    $entries = [System.Collections.Generic.List[object]]::new()
    $tops = @{}
    foreach ($e in $list) {
        $rel = [string]$e['rel']
        Assert-TransferName -Name $rel
        $size = $e['size']
        if ($size -isnot [int64] -and $size -isnot [int32]) { throw 'La máquina de origen dio un tamaño que no es válido.' }
        if ($size -lt 0) { throw 'La máquina de origen dio un tamaño que no es válido.' }
        $top = $rel.Split('\')[0]
        $tops[$top] = $true
        $entries.Add([pscustomobject]@{ Rel = $rel; Full = [string]$e['full']; Size = [int64]$size; Dir = [bool]$e['dir'] })
    }
    [pscustomobject]@{ Entries = $entries; Skipped = [int]$raw['skipped'] }
}

# One file of the source VM into the stream, 4 MB at a time: exactly the size it reported (more or less means the
# file changed, or the VM lies, and the copy stops).
function Copy-GuestFileToPipe {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][hashtable]$Pipe)
    $offset = [int64]0
    while ($offset -lt $Entry.Size) {
        $want = [int][math]::Min($script:TransferChunk, $Entry.Size - $offset)
        $bytes = Invoke-Command -Session $Session -ErrorAction Stop -ArgumentList $Entry.Full, $offset, $want -ScriptBlock {
            param($path, [int64]$at, [int]$count)
            $s = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
            try {
                $null = $s.Seek($at, 'Begin')
                $b = [byte[]]::new($count); $n = 0
                while ($n -lt $count -and ($r = $s.Read($b, $n, $count - $n)) -gt 0) { $n += $r }
                if ($n -lt $count) { $c = [byte[]]::new($n); [Array]::Copy($b, $c, $n); $b = $c }
                , $b
            }
            finally { $s.Dispose() }
        }
        # A byte[] comes back as one object; @($bytes)[-1] would unroll it and keep its last byte.
        if ($bytes -isnot [byte[]] -and $bytes -is [Array]) { $bytes = $bytes[-1] }
        if ($bytes -isnot [byte[]] -or $bytes.Length -ne $want) { throw "$($Entry.Rel) cambió mientras se enviaba; vuelve a intentarlo." }
        Write-TransferBytes -Pipe $Pipe -Bytes $bytes
        $offset += $want
    }
}

# The big files, each written into the hidden folder by several sessions at once (every lane writes every n-th 4 MB
# part at its offset). From another VM each lane also reads its parts there: the bytes only pass through memory.
function Copy-TransferBigFiles {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$FromVM,
        [Parameter(Mandatory)][object[]]$Big,
        [Parameter(Mandatory)][string]$Staging,
        [Parameter(Mandatory)][hashtable]$Pipe
    )
    $sum = [int64]($Big | Measure-Object -Property Size -Sum).Sum
    # One lane per 64 MB, up to 8: opening a session costs ~0.2 s and a small file gains nothing from more.
    $lanes = [int][math]::Min($script:TransferLanes, [math]::Max(1, [math]::Ceiling($sum / 64MB)))
    $targetCred = Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $Name)
    $targets = @(1..$lanes | ForEach-Object { New-PSSession -VMName $Name -Credential $targetCred -ErrorAction Stop })
    $sources = @()
    if ($FromVM) {
        $sourceCred = Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $FromVM)
        $sources = @(1..$lanes | ForEach-Object { New-PSSession -VMName $FromVM -Credential $sourceCred -ErrorAction Stop })
    }
    $chunkSize = $script:TransferChunk
    $marker = $Pipe.Marker
    try {
        foreach ($file in $Big) {
            $dest = Join-Path $Staging $file.Rel
            Invoke-Command -Session $targets[0] -ErrorAction Stop -ArgumentList $dest, $file.Size -ScriptBlock {
                param($p, [int64]$len)
                New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
                $s = [IO.File]::Create($p); $s.SetLength($len); $s.Dispose()
            }
            $state = [hashtable]::Synchronized(@{ bytes = [int64]0; error = $null })
            $job = 0..($lanes - 1) | ForEach-Object -ThrottleLimit $lanes -AsJob -Parallel {
                $lane = $_
                $entry = $using:file; $count = $using:lanes; $size = $using:chunkSize; $state = $using:state; $stop = $using:marker
                $t = ($using:targets)[$lane]
                $src = if ($using:FromVM) { ($using:sources)[$lane] } else { $null }
                $local = $null
                try {
                    Invoke-Command -Session $t -ErrorAction Stop -ArgumentList $using:dest -ScriptBlock { param($p) $global:lane = [IO.File]::Open($p, 'Open', 'Write', 'ReadWrite') }
                    if (-not $src) { $local = [IO.File]::Open($entry.Full, 'Open', 'Read', 'ReadWrite') }
                    $buf = [byte[]]::new($size)
                    for ($at = [int64]$lane * $size; $at -lt $entry.Size; $at += [int64]$count * $size) {
                        if ($state.error -or (Test-Path -LiteralPath $stop)) { break }
                        $want = [int][math]::Min($size, $entry.Size - $at)
                        if ($src) {
                            $bytes = (Invoke-Command -Session $src -ErrorAction Stop -ArgumentList $entry.Full, $at, $want -ScriptBlock {
                                param($path, [int64]$from, [int]$n)
                                $s = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
                                try {
                                    $null = $s.Seek($from, 'Begin')
                                    $b = [byte[]]::new($n); $got = 0
                                    while ($got -lt $n -and ($r = $s.Read($b, $got, $n - $got)) -gt 0) { $got += $r }
                                    if ($got -lt $n) { $c = [byte[]]::new($got); [Array]::Copy($b, $c, $got); $b = $c }
                                    , $b
                                }
                                finally { $s.Dispose() }
                            })
                            # One byte[] back (not wrapped in @(): that would unroll it into its bytes).
                            if ($bytes -isnot [byte[]] -and $bytes -is [Array]) { $bytes = $bytes[-1] }
                        }
                        else {
                            $null = $local.Seek($at, 'Begin')
                            $got = 0
                            while ($got -lt $want -and ($r = $local.Read($buf, $got, $want - $got)) -gt 0) { $got += $r }
                            if ($got -eq $buf.Length) { $bytes = $buf } else { $bytes = [byte[]]::new($got); [Array]::Copy($buf, $bytes, $got) }
                        }
                        # Exactly the size the file had when it was measured: more or less means it changed (or the
                        # source VM lies), and the copy stops.
                        if ($bytes -isnot [byte[]] -or $bytes.Length -ne $want) { $state.error = "$($entry.Rel) cambió mientras se enviaba; vuelve a intentarlo."; break }
                        Invoke-Command -Session $t -ErrorAction Stop -ArgumentList $at, $bytes -ScriptBlock {
                            param([int64]$from, [byte[]]$b)
                            $null = $global:lane.Seek($from, 'Begin'); $global:lane.Write($b, 0, $b.Length)
                        }
                        [Threading.Monitor]::Enter($state.SyncRoot)
                        try { $state.bytes += $want } finally { [Threading.Monitor]::Exit($state.SyncRoot) }
                    }
                }
                catch { if (-not $state.error) { $state.error = "$_" } }
                finally {
                    if ($local) { $local.Dispose() }
                    Invoke-Command -Session $t -ErrorAction SilentlyContinue -ScriptBlock { if ($global:lane) { $global:lane.Dispose() } }
                }
            }
            try {
                # Wait-Job's timeout is whole seconds (0.5 became 0 and this loop spun, flooding the app with progress):
                # the job's own state, checked twice a second.
                while ($job.State -in 'NotStarted', 'Running') {
                    Start-Sleep -Milliseconds 500
                    Write-TransferProgress -Percent ([math]::Min(99, [math]::Floor(100 * ($Pipe.Sent + $state.bytes) / $Pipe.Total))) -Sent ($Pipe.Sent + $state.bytes) -Total $Pipe.Total
                }
            }
            finally { $job | Remove-Job -Force }
            if (Test-Path -LiteralPath $marker) { throw [OperationCanceledException]::new('Envío cancelado.') }
            if ($state.error) { throw $state.error }
            $Pipe.Sent += $file.Size
        }
    }
    finally {
        $targets + $sources | Remove-PSSession -ErrorAction SilentlyContinue
    }
}