function Get-SharedDiskRoot { Join-Path (Get-GpuVMDefaultRoot) '.shared' }

function Get-SharedDiskPath {
    param([Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name)
    Join-Path (Get-SharedDiskRoot) "$Name.vhdx"
}

# NTFS labels allow 32 characters.
function Get-SharedDiskLabel {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name.Length -gt 32) { $Name.Substring(0, 32) } else { $Name }
}

function Read-SharedDisk {
    param([Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name)
    $path = Get-SharedDiskPath -Name $Name
    if (-not (Test-Path -LiteralPath $path)) { throw "The shared disk '$Name' doesn't exist." }
    $metaPath = [IO.Path]::ChangeExtension($path, '.json')
    $meta = if (Test-Path -LiteralPath $metaPath) { Read-JsonFile $metaPath } else { [ordered]@{ purpose = 'general' } }
    $meta['name'] = $Name
    $meta['path'] = $path
    $meta['label'] = Get-SharedDiskLabel $Name
    $meta
}

function Get-SharedDiskAttachment {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    Get-VM | Get-VMHardDiskDrive | Where-Object { $_.Path -and [IO.Path]::GetFullPath($_.Path) -eq $full } | Select-Object -First 1
}

$script:GuestSharedDiskSetup = {
    param($label, $purpose)
    $ErrorActionPreference = 'Stop'
    # Disconnecting takes the disk offline, and Windows remembers it: bring it back. Only data disks can be offline.
    Get-Disk | Where-Object IsOffline | ForEach-Object { Set-Disk -Number $_.Number -IsOffline $false -ErrorAction SilentlyContinue }
    $volume = $null
    for ($i = 0; $i -lt 30 -and -not $volume; $i++) {
        $volume = Get-Volume -FileSystemLabel $label -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $volume) { Start-Sleep -Seconds 1 }
    }
    if (-not $volume) { return @{ status = 'missing' } }
    $letter = [string]$volume.DriveLetter
    if (-not $letter -or $letter -eq [char]0) {
        $used = @(Get-Volume | Where-Object DriveLetter | ForEach-Object { [string]$_.DriveLetter }) + @(Get-PSDrive -PSProvider FileSystem | ForEach-Object Name)
        # Windows PowerShell 5.1 runs this: no 'G'..'Z' ranges.
        $letter = [string](@([char[]](71..90) | ForEach-Object { [string]$_ } | Where-Object { $_ -notin $used }) | Select-Object -First 1)
        $partition = Get-Partition | Where-Object { $_.AccessPaths -contains $volume.Path } | Select-Object -First 1
        Set-Partition -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -NewDriveLetter $letter
    }
    $result = @{ status = 'ready'; letter = $letter; steam = 'none' }
    if ($purpose -ne 'games') { return $result }

    $library = "${letter}:\SteamLibrary"
    # Another VM wrote this disk: a SteamLibrary or steamapps that is a link would have Steam's service work elsewhere.
    foreach ($path in $library, "$library\steamapps") {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $result.steam = 'link'; return $result }
    }
    New-Item -ItemType Directory -Path $library -Force | Out-Null
    $vdf = Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\libraryfolders.vdf'
    if (-not (Test-Path -LiteralPath $vdf)) { return $result }
    $escaped = $library.Replace('\', '\\')
    # Windows PowerShell 5.1 reads a UTF-8 file without BOM as ANSI; libraries with accents would be mangled.
    $utf8 = [Text.UTF8Encoding]::new($false)
    $text = [IO.File]::ReadAllText($vdf, $utf8)
    if ($text.Contains("`"$escaped`"")) { $result.steam = 'registered'; return $result }
    # Steam rewrites the file when it exits: an open Steam is closed first, and a game in progress means nothing is touched.
    $steamExe = Join-Path ${env:ProgramFiles(x86)} 'Steam\steam.exe'
    $runAsUser = {
        param($arguments)
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        if (-not $user) { return }
        $task = "GpuVM-Steam-$([guid]::NewGuid().ToString('n'))"
        $action = New-ScheduledTaskAction -Execute $steamExe -Argument $arguments
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Force | Out-Null
        try { Start-ScheduledTask -TaskName $task; Start-Sleep -Seconds 2 }
        finally { Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue }
    }
    $wasOpen = [bool](Get-Process steam -ErrorAction SilentlyContinue)
    if ($wasOpen) {
        & $runAsUser '-shutdown'
        for ($i = 0; $i -lt 60 -and (Get-Process steam -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 1 }
        if (Get-Process steam -ErrorAction SilentlyContinue) { $result.steam = 'running'; return $result }
        $text = [IO.File]::ReadAllText($vdf, $utf8)
        if ($text.Contains("`"$escaped`"")) { & $runAsUser '-silent'; $result.steam = 'registered'; return $result }
    }
    $next = (@([regex]::Matches($text, '(?m)^\t"(\d+)"\s*$') | ForEach-Object { [int]$_.Groups[1].Value }) | Measure-Object -Maximum).Maximum + 1
    $id = [string](Get-Random -Minimum 1000000000 -Maximum 2147483647)
    $entry = "`t`"$next`"`n`t{`n`t`t`"path`"`t`t`"$escaped`"`n`t`t`"label`"`t`t`"`"`n`t`t`"contentid`"`t`t`"$id`"`n`t`t`"totalsize`"`t`t`"0`"`n" +
        "`t`t`"update_clean_bytes_tally`"`t`t`"0`"`n`t`t`"time_last_update_verified`"`t`t`"0`"`n`t`t`"apps`"`n`t`t{`n`t`t}`n`t}`n"
    $end = $text.LastIndexOf('}')
    Copy-Item -LiteralPath $vdf -Destination "$vdf.gpuvm.bak" -Force
    # UTF-8 without BOM, as Steam writes it.
    [IO.File]::WriteAllText($vdf, $text.Substring(0, $end) + $entry + $text.Substring($end), $utf8)
    if ($wasOpen) { & $runAsUser '-silent' }
    $result.steam = 'registered'
    $result
}

function Initialize-GuestSharedDisk {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Disk
    )
    $r = Invoke-Guest -Name $VMName -Credential $Credential -ScriptBlock $script:GuestSharedDiskSetup -ArgumentList $Disk['label'], $Disk['purpose']
    # Only primitive values from the guest are used.
    $status = [string]$r['status']
    $letter = [string]$r['letter']
    if ($letter -notmatch '^[A-Z]$') { $letter = '' }
    switch ($status) {
        'ready' { Write-Step "Disk '$($Disk['name'])' at $letter`: inside the VM" }
        default { Write-Warning "The VM doesn't show the disk '$($Disk['name'])' yet." }
    }
    switch ([string]$r['steam']) {
        'registered' { Write-Step "Steam library at $letter`:\SteamLibrary" }
        'link' { Write-Warning "The disk '$($Disk['name'])' has a link in SteamLibrary (left by another machine); it won't be added to Steam. Check it before using it." }
        'running' { Write-Warning "Steam couldn't be closed in the VM (is a game open?): close it and connect the disk again to add $letter`:\SteamLibrary to its libraries." }
    }
    $letter
}

function Assert-ImportableFolder {
    param([Parameter(Mandatory)][string]$Path)
    $source = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($source.Length -le 3) { throw 'A whole drive can''t be imported; choose a folder.' }
    $inside = @((Get-GpuVMDefaultRoot), $script:DataRoot, $env:SystemRoot)
    $notAbove = @($inside + [Environment]::GetFolderPath('ProgramFiles') + ${env:ProgramFiles(x86)} + $env:ProgramData +
        (Split-Path ([Environment]::GetFolderPath('UserProfile')) -Parent)) | Where-Object { $_ }
    foreach ($protected in $notAbove) {
        $p = [IO.Path]::GetFullPath($protected).TrimEnd('\')
        $sourceAbove = "$p\".StartsWith("$source\", [StringComparison]::OrdinalIgnoreCase)
        $sourceInside = $p -in $inside -and "$source\".StartsWith("$p\", [StringComparison]::OrdinalIgnoreCase)
        if ($sourceAbove -or $sourceInside) { throw "${source} can't be imported: it contains or is inside $p." }
    }
}

# Fails closed: a folder that can't be listed (a guest can deny access) or any link stops the copy.
function Assert-NoReparsePointBelow {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($Path)
    while ($pending.Count) {
        $dir = $pending.Pop()
        try { $entries = [IO.DirectoryInfo]::new($dir).GetFileSystemInfos() }
        catch { throw "Couldn't check $($dir.Substring($Root.Length)) on the disk; nothing is copied into it." }
        foreach ($entry in $entries) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "The disk has a link at $($entry.FullName.Substring($Root.Length)); nothing is copied into it."
            }
            if ($entry -is [IO.DirectoryInfo]) { $pending.Push($entry.FullName) }
        }
    }
}
