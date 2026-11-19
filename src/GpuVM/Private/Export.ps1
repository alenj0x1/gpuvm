# Export and import: a whole VM in one .gpuvm file, to keep it safe or take it to another PC.
# The file is a zip with two entries: disk.vhdx (the VM's Windows merged into one dynamic disk, its parents and
# restore points included, with the space of deleted files given back) and manifest.json (name, edition, apps, user
# name, the disk's SHA-256). Nothing protected with this PC's DPAPI goes in it: no Windows password, no Sunshine
# credentials, no pairing. Import asks for the Windows password, gives the copy its own streaming identity and web
# credentials, and the viewer pairs again.

Add-Type -AssemblyName System.IO.Compression
$script:TransferFormat = 1
$script:TransferExtension = '.gpuvm'

# Copies $Source into $Destination while hashing it, reporting progress as "<Label> N %".
function Copy-StreamWithHash {
    param(
        [Parameter(Mandatory)][IO.Stream]$Source,
        [Parameter(Mandatory)][IO.Stream]$Destination,
        [Parameter(Mandatory)][int64]$Length,
        [Parameter(Mandatory)][string]$Label,
        # Stops at this many bytes: a file that says it holds less than it does is not trusted.
        [int64]$Limit = [int64]::MaxValue
    )
    $sha = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $buffer = [byte[]]::new(4MB)
    $done = [int64]0
    $lastReport = [Diagnostics.Stopwatch]::StartNew()
    try {
        while (($read = $Source.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $done += $read
            if ($done -gt $Limit) { throw 'The file holds more data than it says; it isn''t imported.' }
            $sha.AppendData($buffer, 0, $read)
            $Destination.Write($buffer, 0, $read)
            if ($lastReport.ElapsedMilliseconds -ge 1000) {
                $percent = if ($Length -gt 0) { [math]::Min(99, [math]::Floor($done * 100 / $Length)) } else { 0 }
                Write-Step "$Label $percent %"
                $lastReport.Restart()
            }
        }
        [pscustomobject]@{ Bytes = $done; Sha256 = [Convert]::ToHexString($sha.GetHashAndReset()).ToLowerInvariant() }
    }
    finally { $sha.Dispose() }
}

# Every disk in a chain (the VM's, its restore points', its template's) adds up to at most what Convert-VHD writes.
function Get-VhdChainBytes {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [int64]0
    $vhd = Get-VHD -Path $Path
    for ($i = 0; $vhd -and $i -lt 32; $i++) {
        $bytes += $vhd.FileSize
        $vhd = if ($vhd.ParentPath) { Get-VHD -Path $vhd.ParentPath -ErrorAction SilentlyContinue }
    }
    $bytes
}

# What GpuVM keeps about the VM in the file: only plain facts about its Windows, never secrets or paths.
function New-TransferManifest {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State, [Parameter(Mandatory)][int64]$SizeBytes)
    [ordered]@{
        format        = $script:TransferFormat
        kind          = 'gpuvm-machine'
        name          = $State['name']
        exportedAt    = (Get-Date).ToString('o')
        toolVersion   = $script:ToolVersion
        edition       = $State['edition']
        profile       = $State['profile']
        user          = if ($State['guest']) { $State['guest']['user'] } else { $null }
        installedApps = @(if ($State.Contains('installedApps')) { $State['installedApps'] })
        pendingApps   = @(if ($State.Contains('pendingApps')) { $State['pendingApps'] })
        cleanup       = if ($State['config'] -and $State['config']['guest']) { $State['config']['guest']['cleanup'] } else { $null }
        driverVersion = if ($State['gpu']) { $State['gpu']['driverVersion'] } else { $null }
        diskSizeBytes = $SizeBytes
        disk          = $null
    }
}

# A manifest comes from a file of unknown origin: each value is checked and only known fields are kept.
function Read-TransferManifest {
    param([Parameter(Mandatory)][string]$Text)
    if ($Text.Length -gt 64KB) { throw 'The file isn''t a GpuVM machine.' }
    try { $m = $Text | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { throw 'The file isn''t a GpuVM machine.' }
    if ($m -isnot [System.Collections.IDictionary] -or $m['kind'] -ne 'gpuvm-machine') { throw 'The file isn''t a GpuVM machine.' }
    if ($m['format'] -isnot [long] -and $m['format'] -isnot [int]) { throw 'The file isn''t a GpuVM machine.' }
    if ([int]$m['format'] -gt $script:TransferFormat) { throw 'The machine was exported with a newer GpuVM. Update GpuVM to import it.' }
    $disk = $m['disk']
    if ($disk -isnot [System.Collections.IDictionary] -or "$($disk['sha256'])" -notmatch '^[0-9a-f]{64}$' -or
        ($disk['bytes'] -isnot [long] -and $disk['bytes'] -isnot [int]) -or [int64]$disk['bytes'] -le 0) {
        throw 'The file is incomplete: its disk or its fingerprint is missing.'
    }
    # Not $text: PowerShell names ignore case and that is the -Text parameter.
    $pick = { param($v, $pattern) if ($v -is [string] -and $v -match $pattern) { $v } else { $null } }
    $pickIds = { param($v) @(@($v) | Where-Object { $_ -is [string] -and $_ -match '^[\w.-]{1,64}$' } | Select-Object -First 200) }
    [ordered]@{
        format        = [int]$m['format']
        name          = & $pick $m['name'] '^[\w-]{1,40}$'
        exportedAt    = & $pick $m['exportedAt'] '^[\d\-T:.+Z]{10,40}$'
        toolVersion   = & $pick $m['toolVersion'] '^[\w.\-]{1,20}$'
        edition       = & $pick $m['edition'] '^[\w .()\-]{1,60}$'
        profile       = & $pick $m['profile'] '^[\w-]{1,40}$'
        user          = & $pick $m['user'] '^[\w.\-]{1,20}$'
        installedApps = & $pickIds $m['installedApps']
        pendingApps   = & $pickIds $m['pendingApps']
        cleanup       = & $pick $m['cleanup'] '^[\w-]{1,20}$'
        driverVersion = & $pick $m['driverVersion'] '^[\d.]{1,30}$'
        diskSizeBytes = if ($m['diskSizeBytes'] -is [long] -or $m['diskSizeBytes'] -is [int]) { [int64]$m['diskSizeBytes'] } else { $null }
        disk          = [ordered]@{ bytes = [int64]$disk['bytes']; sha256 = [string]$disk['sha256'] }
    }
}

function Open-TransferArchive {
    param([Parameter(Mandatory)][string]$Path)
    # Opened once, checked to be the very file asked for (no folder of the path swapped for a link since the service
    # checked it as the user), and read only through this handle.
    $stream = Open-GpuVMSafeFile -Path ([IO.Path]::GetFullPath($Path))
    try { $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $false) }
    catch { $stream.Dispose(); throw 'The file isn''t a GpuVM machine.' }
    $manifestEntry = $zip.GetEntry('manifest.json')
    $diskEntry = $zip.GetEntry('disk.vhdx')
    if (-not $manifestEntry -or -not $diskEntry) { $zip.Dispose(); throw 'The file isn''t a GpuVM machine.' }
    try {
        $reader = [IO.StreamReader]::new($manifestEntry.Open())
        try { $manifest = Read-TransferManifest -Text $reader.ReadToEnd() } finally { $reader.Dispose() }
        if ($diskEntry.Length -ne $manifest['disk']['bytes']) { throw 'The file is damaged: the disk isn''t the size it says.' }
    }
    catch { $zip.Dispose(); throw }
    [pscustomobject]@{ Zip = $zip; Manifest = $manifest; DiskEntry = $diskEntry; Length = $stream.Length }
}

# GpuVM writes the file as administrator: never inside Windows, the programs' folders, ProgramData or GpuVM's own
# folders, never through a link, and never over an existing file (the caller opens it with CreateNew).
function Assert-GpuVMExportPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\') { throw 'Choose a folder on a drive of this PC.' }
    $protected = @(
        [Environment]::GetFolderPath('Windows'), [Environment]::GetFolderPath('ProgramFiles'),
        [Environment]::GetFolderPath('ProgramFilesX86'), [Environment]::GetFolderPath('CommonApplicationData'),
        (Get-GpuVMDefaultRoot)
    ) | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
    foreach ($dir in $protected) {
        if ($full.StartsWith("$dir\", [StringComparison]::OrdinalIgnoreCase)) { throw "It can't be saved in $dir. Choose another folder, such as Documents." }
    }
    $item = Get-Item -LiteralPath (Split-Path $full -Parent) -Force -ErrorAction Stop
    for ($cur = $item; $cur; $cur = $cur.Parent) {
        if ($cur.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$($cur.FullName) is a link to another folder; choose another one." }
    }
    $full
}

# The first name of "<base>", "<base>-2", "<base>-3"… free in Hyper-V and in GpuVM's folder.
function Get-FreeGpuVMName {
    param([Parameter(Mandatory)][string]$Base)
    $root = Get-GpuVMDefaultRoot
    for ($i = 1; $i -lt 100; $i++) {
        $candidate = if ($i -eq 1) { $Base } else { $suffix = "-$i"; $Base.Substring(0, [math]::Min($Base.Length, 40 - $suffix.Length)) + $suffix }
        if (-not (Get-VM -Name $candidate -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath (Join-Path $root $candidate))) { return $candidate }
    }
    throw "There's no free name for '$Base'."
}

# An imported machine gets its own streaming identity and Sunshine web login inside the VM, over PowerShell Direct,
# the first time it is opened: the disk came from a file of unknown origin and is never mounted on this PC. Sunshine
# is stopped, its identity and certificate are removed (it makes new ones when it starts), and the web login is set
# with sunshine.exe --creds, as GpuVM's guest setup does. Windows restarts afterwards so Sunshine starts as usual.
function Reset-GuestStreamingIdentity {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][pscredential]$WebCredential
    )
    $user = $WebCredential.UserName
    $password = $WebCredential.GetNetworkCredential().Password
    $result = Invoke-Guest -Name $Name -Credential $Credential -ArgumentList $user, $password -ScriptBlock {
        param($user, $password)
        $dir = Join-Path $env:ProgramFiles 'Sunshine'
        $exe = Join-Path $dir 'sunshine.exe'
        if (-not (Test-Path $exe)) { return 'no-sunshine' }
        Get-Service SunshineService -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
        Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $config = Join-Path $dir 'config'
        $statePath = Join-Path $config 'sunshine_state.json'
        if (Test-Path $statePath) {
            $state = Get-Content -Raw $statePath | ConvertFrom-Json
            if ($state -and $state.PSObject.Properties['root']) { $state.PSObject.Properties.Remove('root') }
            # Without a byte order mark: Sunshine's JSON reader doesn't take one.
            [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 10))
        }
        foreach ($pem in 'cacert.pem', 'cakey.pem') { Remove-Item (Join-Path $config "credentials\$pem") -Force -ErrorAction SilentlyContinue }
        Push-Location $dir
        try { & $exe --creds $user $password | Out-Null } finally { Pop-Location }
        'ok'
    }
    if ("$result" -ne 'ok') { throw "Couldn't give the machine its own streaming identity ($result)." }
}