$script:TransferChunk = 4MB
$script:TransferDirectMin = 16MB
$script:TransferLanes = 8
# Names and counts a guest (the source of a VM -> VM copy) may report: anything else stops the copy.
$script:TransferMaxEntries = 200000
$script:TransferMaxName = 1024

function Get-TransferMarker {
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{8,32}$')][string]$Id)
    Join-Path (Get-DataPath 'transfers') "$Id.cancel"
}

function Assert-SendablePath {
    param([Parameter(Mandatory)][string]$Path)
    # A full path as given (a relative one would be resolved against this process's folder, not checked by the service).
    if ($Path -notmatch '^[A-Za-z]:\\.' -or $Path -match '\\\.\.?(\\|$)') { throw "$Path isn't a file or folder on a disk of this PC." }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if (-not $item) { throw "$full doesn't exist." }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$full is a link; choose the real location." }
    if ($item -is [IO.DirectoryInfo]) { Assert-ImportableFolder -Path $full; return }
    foreach ($protected in @((Get-GpuVMDefaultRoot), $script:DataRoot, $env:SystemRoot) | Where-Object { $_ }) {
        $p = [IO.Path]::GetFullPath($protected).TrimEnd('\')
        if ("$full\".StartsWith("$p\", [StringComparison]::OrdinalIgnoreCase)) { throw "${full} can't be sent: it's inside $p." }
    }
}

# A name from a guest: no drive, no "..", no stream (":"), no control or reserved characters, or it writes outside the folder.
function Assert-TransferName {
    param([AllowEmptyString()][string]$Name)
    if (-not $Name -or $Name.Length -gt $script:TransferMaxName) { throw 'A file name isn''t valid; nothing is copied.' }
    foreach ($part in $Name.Split('\')) {
        if (-not $part -or $part -eq '.' -or $part -eq '..' -or $part.Length -gt 255 -or $part -match '[\x00-\x1f<>:"/|?*]' -or $part -match '[ .]$') {
            throw "The name $Name isn't valid; nothing is copied."
        }
    }
}

function Initialize-UserFiles {
    if (-not ('GpuVM.UserFiles' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'UserFiles.cs') }
}

function Get-InnerMessage {
    param($ErrorRecord)
    $e = $ErrorRecord.Exception
    while ($e -is [Management.Automation.MethodInvocationException] -and $e.InnerException) { $e = $e.InnerException }
    $e.Message
}

function Get-HostTransferEntries {
    param([Parameter(Mandatory)][string[]]$Path)
    Initialize-UserFiles
    $entries = [System.Collections.Generic.List[object]]::new()
    $tops = @{}
    $skipped = 0
    foreach ($p in $Path) {
        Assert-SendablePath -Path $p
        $full = [IO.Path]::GetFullPath($p).TrimEnd('\')
        $item = Get-Item -LiteralPath $full -Force
        $isDir = $item -is [IO.DirectoryInfo]
        $top = Get-UniqueName -Name $item.Name -Taken $tops
        $tops[$top] = $true
        try {
            $root = [GpuVM.UserFiles]::Root($full, $isDir)
            if (-not $isDir) { $entries.Add([pscustomobject]@{ Rel = $top; Full = $full; Size = $item.Length; Dir = $false; Root = $root }); continue }
            $entries.Add([pscustomobject]@{ Rel = $top; Full = $full; Size = 0; Dir = $true; Root = $root })
            $links = 0
            foreach ($e in [GpuVM.UserFiles]::List($full, $top, $root, [ref]$links)) {
                $entries.Add([pscustomobject]@{ Rel = $e.Rel; Full = $e.Full; Size = $e.Size; Dir = $e.Dir; Root = $root })
            }
            $skipped += $links
        }
        catch [Management.Automation.MethodInvocationException] { throw (Get-InnerMessage $_) }
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

# The desktop's path and folder are the person's (on an agent machine, `agent`'s) and this runs as administrator:
# unpacked in an admin-only folder, and the destination is only used while Enter-GpuVMDestination holds it.
function Open-GuestReceiver {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Folder)
    $answer = Invoke-Command -Session $Session -ErrorAction Stop -ArgumentList $Id, $Folder, $script:GuestDesktopResolver.ToString(), $script:GuestFolderCode -ScriptBlock {
        param($id, $folder, $resolver, $folderCode)
        . ([scriptblock]::Create($folderCode))
        $desktop = $null
        $profilePath = $null
        $sid = $null
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        if ($user) {
            try {
                $sid = ([Security.Principal.NTAccount]$user).Translate([Security.Principal.SecurityIdentifier]).Value
                $profilePath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid").ProfileImagePath
                $desktop = & ([scriptblock]::Create($resolver)) "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" $profilePath
            }
            catch { $desktop = $null }
        }
        if (-not $desktop) {
            $desktop = [Environment]::GetFolderPath('Desktop')
            $profilePath = $env:USERPROFILE
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        }
        $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
        if (-not (Test-Path $tar)) { return @{ error = 'Windows in the machine has no tar.exe (Windows 10 1803 or later is needed).' } }
        try { $guard = Enter-GpuVMDestination -ProfilePath $profilePath -Desktop $desktop -Folder $folder -Id $id -Create }
        catch { return @{ error = "$($_.Exception.Message)" } }
        try {
            $dest = $guard.Dest
            if ($folder -eq 'Received') {
                $shown = @{ es = 'Recibidos' }[[Globalization.CultureInfo]::InstalledUICulture.TwoLetterISOLanguageName]
                $ini = Join-Path $dest 'desktop.ini'
                if ($shown -and -not (Test-Path -LiteralPath $ini)) {
                    # CreateNew: never written through a file (or link) put there in the meantime.
                    $bytes = [Text.Encoding]::Unicode.GetPreamble() + [Text.Encoding]::Unicode.GetBytes("[.ShellClassInfo]`r`nLocalizedResourceName=$shown`r`n")
                    $s = [IO.FileStream]::new($ini, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    try { $s.Write([byte[]]$bytes, 0, $bytes.Length) } finally { $s.Dispose() }
                    (Get-Item -LiteralPath $ini -Force).Attributes = 'Hidden, System'
                    # Explorer only reads desktop.ini in a folder marked read-only (files can still go in).
                    $dir = Get-Item -LiteralPath $dest -Force
                    $dir.Attributes = $dir.Attributes -bor [IO.FileAttributes]::ReadOnly
                }
            }
        }
        finally { & $guard.Close }
        # On the destination's volume, so what is unpacked there moves into place without being copied.
        $staging = New-GpuVMAdminFolder -Volume ([IO.Path]::GetPathRoot($dest)) -Prefix 'GpuVM-receive'
        $psi = [Diagnostics.ProcessStartInfo]::new($tar, "-x -f - -C `"$staging`"")
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardError = $true
        if (-not (Test-Path variable:global:GpuVMReceive)) { $global:GpuVMReceive = @{} }
        $process = [Diagnostics.Process]::Start($psi)
        $global:GpuVMReceive[$id] = @{ process = $process; dest = $dest; staging = $staging; error = $process.StandardError.ReadToEndAsync()
            profile = $profilePath; desktop = $desktop; folder = $folder; sid = $sid }
        $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($dest))
        @{ dest = $dest; staging = $staging; free = [int64]$drive.AvailableFreeSpace }
    }
    $answer = @($answer)[-1]
    if ($answer['error']) { throw (ConvertTo-GuestString $answer['error'] -MaxLength 400) }
    [pscustomobject]@{ Dest = ConvertTo-GuestString $answer['dest'] -MaxLength 400; Staging = ConvertTo-GuestString $answer['staging'] -MaxLength 460; Free = [int64]$answer['free'] }
}

function Send-GuestBytes {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][byte[]]$Bytes)
    Invoke-Command -Session $Session -ErrorAction Stop -ArgumentList $Id, $Bytes -ScriptBlock {
        param($id, [byte[]]$b)
        $global:GpuVMReceive[$id].process.StandardInput.BaseStream.Write($b, 0, $b.Length)
    }
}

# REG_EXPAND_SZ read unexpanded: Get-ItemProperty would expand it with the PowerShell Direct user's variables.
$script:GuestDesktopResolver = {
    param([string]$KeyPath, [string]$ProfilePath)
    $key = Get-Item -LiteralPath $KeyPath -ErrorAction SilentlyContinue
    $raw = if ($key) { $key.GetValue('Desktop', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { $null }
    if (-not $raw) { return (Join-Path $ProfilePath 'Desktop') }
    $path = ([string]$raw) -ireplace '%USERPROFILE%', $ProfilePath.Replace('$', '$$')
    if ($path -match '%[^%]+%' -or -not [IO.Path]::IsPathRooted($path)) { return (Join-Path $ProfilePath 'Desktop') }
    $path
}

function Close-GuestReceiver {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Id, [switch]$Cancel)
    $answer = Invoke-Command -Session $Session -ErrorAction Stop -ArgumentList @($Id, $Cancel.IsPresent, $script:GuestFolderCode) -ScriptBlock {
        param($id, $cancel, $folderCode)
        . ([scriptblock]::Create($folderCode))
        $r = $global:GpuVMReceive[$id]
        if (-not $r) { return @{ ok = $false; error = 'nothing was receiving' } }
        $global:GpuVMReceive.Remove($id)
        $p = $r.process
        try { $p.StandardInput.Close() } catch { }
        if ($cancel) { try { $p.Kill() } catch { } }
        $null = $p.WaitForExit(60000)
        $ok = -not $cancel -and $p.HasExited -and $p.ExitCode -eq 0
        $err = if ($ok -or $cancel) { '' } else { "tar $(if ($p.HasExited) { $p.ExitCode } else { 'still running' }): $("$($r.error.Result)".Trim())" }
        $names = @()
        $bytes = [int64]0; $files = 0
        if ($ok) {
            try {
                $items = @(Get-ChildItem -LiteralPath $r.staging -Force)
                # Measured where only administrators can write: the sender compares it with what it sent.
                foreach ($item in $items) {
                    if ($item.PSIsContainer) {
                        foreach ($f in Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force) { $bytes += $f.Length; $files++ }
                    }
                    else { $bytes += $item.Length; $files++ }
                }
                $who = New-Object Security.Principal.SecurityIdentifier $r.sid
                foreach ($item in $items) {
                    $acl = $item.GetAccessControl('Access')
                    $rule = if ($item.PSIsContainer) {
                        New-Object Security.AccessControl.FileSystemAccessRule ($who, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
                    }
                    else { New-Object Security.AccessControl.FileSystemAccessRule ($who, 'FullControl', 'Allow') }
                    $acl.AddAccessRule($rule)
                    $item.SetAccessControl($acl)
                }
                $guard = Enter-GpuVMDestination -ProfilePath $r.profile -Desktop $r.desktop -Folder $r.folder -Id $id
                try {
                    if ($guard.Dest -ne $r.dest) { throw "The destination changed to $($guard.Dest)." }
                    foreach ($item in $items) {
                        $name = $item.Name
                        $base = if ($item.PSIsContainer) { $name } else { [IO.Path]::GetFileNameWithoutExtension($name) }
                        $ext = if ($item.PSIsContainer) { '' } else { [IO.Path]::GetExtension($name) }
                        # [IO.Directory]::Move and [IO.File]::Move fail when the target exists; Move-Item would move into a folder (or junction).
                        for ($i = 2; ; $i++) {
                            $target = Join-Path $r.dest $name
                            if (-not (Test-Path -LiteralPath $target)) {
                                try {
                                    if ($item.PSIsContainer) { [IO.Directory]::Move($item.FullName, $target) } else { [IO.File]::Move($item.FullName, $target) }
                                    break
                                }
                                catch { if (-not (Test-Path -LiteralPath $target) -or $i -gt 1000) { throw } }
                            }
                            $name = "$base ($i)$ext"
                        }
                        $names += $name
                    }
                }
                finally { & $guard.Close }
            }
            catch {
                $ok = $false
                $err = "$($_.Exception.Message)"
            }
        }
        # Not Remove-Item -Recurse (Windows PowerShell 5.1 goes into junctions): see Remove-GpuVMFolder.
        Remove-GpuVMFolder -Path $r.staging
        @{ ok = $ok; names = $names; error = $err; dest = $r.dest; bytes = $bytes; files = $files }
    }
    $answer = @($answer)[-1]
    [pscustomobject]@{
        Ok    = [bool]$answer['ok']
        Names = @($answer['names'] | ForEach-Object { ConvertTo-GuestString $_ -MaxLength 260 })
        Error = ConvertTo-GuestString $answer['error'] -MaxLength 300
        Dest  = ConvertTo-GuestString $answer['dest'] -MaxLength 400
        Bytes = $(if ($answer['bytes'] -is [int64] -or $answer['bytes'] -is [int32]) { [int64]$answer['bytes'] } else { [int64]-1 })
        Files = $(if ($answer['files'] -is [int32] -or $answer['files'] -is [int64]) { [int]$answer['files'] } else { -1 })
    }
}

function Assert-TransferArrived {
    param([Parameter(Mandatory)]$Done, [int64]$Bytes, [int]$Files, [string]$Name)
    if (-not $Done.Ok) { throw "The machine couldn't save the files. $($Done.Error)" }
    if ($Done.Files -ne $Files -or $Done.Bytes -ne $Bytes) {
        throw "The copy didn't arrive whole in $Name ($($Done.Files) of $Files files, $($Done.Bytes) of $Bytes bytes in $($Done.Dest))."
    }
}

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
    if (Test-Path -LiteralPath $Pipe.Marker) { throw [OperationCanceledException]::new('Copy cancelled.') }
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
    $Sent = [math]::Min($Sent, $Total)
    $unit = if ($Total -ge 1GB) { 1GB, 'GB' } else { 1MB, 'MB' }
    $fmt = { param($n) [math]::Round($n / $unit[0], 1).ToString([cultureinfo]::InvariantCulture) }
    Write-Step "Sending $Percent % · $(& $fmt $Sent) of $(& $fmt $Total) $($unit[1])"
}

function Open-TransferSession {
    param([Parameter(Mandatory)][string]$Name)
    # Sending files keeps state between commands in one PowerShell Direct session, which machines without Hyper-V lack.
    Assert-HyperVMachine -Name $Name -What 'Sending files to the machine'
    $state = Get-GpuVMState -Name $Name
    $guest = Get-GpuVMGuestCredential -State $state
    if (-not $guest) { throw "Save the Windows password of '$Name' to send files to it." }
    if ((Get-VM -Name $Name).State -ne 'Running') { throw "The VM '$Name' is off." }
    New-PSSession -VMName $Name -Credential $guest -ErrorAction Stop
}

function Get-GuestRawEntries {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string[]]$Path)
    Invoke-Command -Session $Session -ErrorAction Stop -ArgumentList (, $Path) -ScriptBlock {
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
}

function Get-GuestTransferEntries {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string[]]$Path)
    $raw = @(Get-GuestRawEntries -Session $Session -Path $Path)[-1]
    $list = @($raw['entries'])
    if ($list.Count -gt $script:TransferMaxEntries) { throw "There are more than $($script:TransferMaxEntries) files; choose fewer." }
    if (-not $list.Count) { throw 'Nothing to send was found in that machine.' }
    $entries = [System.Collections.Generic.List[object]]::new()
    $tops = @{}; $topFrom = $null; $topTo = $null
    foreach ($e in $list) {
        $rel = [string]$e['rel']
        Assert-TransferName -Name $rel
        $size = $e['size']
        if ($size -isnot [int64] -and $size -isnot [int32]) { throw 'The source machine gave a size that isn''t valid.' }
        if ($size -lt 0) { throw 'The source machine gave a size that isn''t valid.' }
        $parts = $rel.Split('\')
        if ($parts.Count -eq 1) {
            $topFrom = $rel
            $topTo = Get-UniqueName -Name $rel -Taken $tops
            $tops[$topTo] = $true
            $rel = $topTo
        }
        elseif ($parts[0] -eq $topFrom) { $rel = $topTo + $rel.Substring($topFrom.Length) }
        else { throw "The name $rel isn't valid; nothing is copied." }
        $entries.Add([pscustomobject]@{ Rel = $rel; Full = [string]$e['full']; Size = [int64]$size; Dir = [bool]$e['dir'] })
    }
    [pscustomobject]@{ Entries = $entries; Skipped = [int]$raw['skipped'] }
}

# The archive is written here: a tar made by the source VM could carry links that write outside the folder.
function Copy-GuestFilesToPipe {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][object[]]$Entries, [Parameter(Mandatory)][hashtable]$Pipe)
    $paths = [string[]]@($Entries | ForEach-Object { $_.Full })
    $answer = Invoke-Command -Session $Session -ErrorAction Stop -ArgumentList (, $paths) -ScriptBlock {
        param([string[]]$list)
        foreach ($p in $list) { , [IO.File]::ReadAllBytes($p) }
    }
    # One file comes back as a byte[]; several as a list of them. Never through @(), which unrolls a byte[].
    $got = [System.Collections.Generic.List[object]]::new()
    if ($answer -is [byte[]]) { $got.Add($answer) } else { foreach ($a in $answer) { $got.Add($a) } }
    if ($got.Count -ne $Entries.Count) { throw 'The source machine didn''t send back every file; try again.' }
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        $entry = $Entries[$i]; $bytes = $got[$i]
        if ($bytes -isnot [byte[]] -or $bytes.Length -ne $entry.Size) { throw "$($entry.Rel) changed while it was sent; try again." }
        Write-TransferBytes -Pipe $Pipe -Bytes (New-TarHeader -Name $entry.Rel -Size $entry.Size)
        if ($bytes.Length) { Write-TransferBytes -Pipe $Pipe -Bytes $bytes }
        $pad = (512 - ($entry.Size % 512)) % 512
        if ($pad) { Write-TransferBytes -Pipe $Pipe -Bytes ([byte[]]::new($pad)) }
    }
}

function Copy-TransferBigFiles {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$FromVM,
        [Parameter(Mandatory)][object[]]$Big,
        [Parameter(Mandatory)][string]$Staging,
        [Parameter(Mandatory)][hashtable]$Pipe
    )
    $sum = [int64]($Big | Measure-Object -Property Size -Sum | ForEach-Object Sum)
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
            # Inside the admin-only hidden folder (Open-GuestReceiver): no user can have put a junction on this path.
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
                    # This PC's files: with the person's rights, and only if still under the folder that was checked.
                    if (-not $src) { $local = [GpuVM.UserFiles]::OpenFile($entry.Full, $entry.Root) }
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
                        # Exactly the measured size: more or less means it changed (or the source VM lies), and the copy stops.
                        if ($bytes -isnot [byte[]] -or $bytes.Length -ne $want) { $state.error = "$($entry.Rel) changed while it was sent; try again."; break }
                        Invoke-Command -Session $t -ErrorAction Stop -ArgumentList $at, $bytes -ScriptBlock {
                            param([int64]$from, [byte[]]$b)
                            $null = $global:lane.Seek($from, 'Begin'); $global:lane.Write($b, 0, $b.Length)
                        }
                        [Threading.Monitor]::Enter($state.SyncRoot)
                        try { $state.bytes += $want } finally { [Threading.Monitor]::Exit($state.SyncRoot) }
                    }
                }
                catch { if (-not $state.error) { $e = $_.Exception; while ($e.InnerException -and $e -is [Management.Automation.MethodInvocationException]) { $e = $e.InnerException }; $state.error = $e.Message } }
                finally {
                    if ($local) { $local.Dispose() }
                    Invoke-Command -Session $t -ErrorAction SilentlyContinue -ScriptBlock { if ($global:lane) { $global:lane.Dispose() } }
                }
            }
            try {
                # Wait-Job's timeout is whole seconds (0.5 becomes 0): the job's own state, checked twice a second.
                while ($job.State -in 'NotStarted', 'Running') {
                    Start-Sleep -Milliseconds 500
                    Write-TransferProgress -Percent ([math]::Min(99, [math]::Floor(100 * ($Pipe.Sent + $state.bytes) / $Pipe.Total))) -Sent ($Pipe.Sent + $state.bytes) -Total $Pipe.Total
                }
            }
            finally { $job | Remove-Job -Force }
            if (Test-Path -LiteralPath $marker) { throw [OperationCanceledException]::new('Copy cancelled.') }
            if ($state.error) { throw $state.error }
            $Pipe.Sent += $file.Size
        }
    }
    finally {
        $targets + $sources | Remove-PSSession -ErrorAction SilentlyContinue
    }
}
