# Shared disks: a data disk (for example, a game library) that moves between VMs. It lives in <root>\.shared\
# as <name>.vhdx plus <name>.json, and is attached to one VM at a time as a SCSI disk (it can be added and
# removed while the VM runs). Inside the VM its NTFS volume is labeled with the disk's name.

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
    if (-not (Test-Path -LiteralPath $path)) { throw "No existe el disco compartido '$Name'." }
    $metaPath = [IO.Path]::ChangeExtension($path, '.json')
    $meta = if (Test-Path -LiteralPath $metaPath) { Read-JsonFile $metaPath } else { [ordered]@{ purpose = 'general' } }
    $meta['name'] = $Name
    $meta['path'] = $path
    $meta['label'] = Get-SharedDiskLabel $Name
    $meta
}

# The VM drive the disk is attached to, if any.
function Get-SharedDiskAttachment {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    Get-VM | Get-VMHardDiskDrive | Where-Object { $_.Path -and [IO.Path]::GetFullPath($_.Path) -eq $full } | Select-Object -First 1
}

# Inside the guest: gives the volume a drive letter if it has none and, for a game disk, prepares SteamLibrary and
# adds it to Steam's libraries (only while Steam is closed: Steam rewrites the file when it exits). Idempotent.
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
    # Another VM wrote this disk: a SteamLibrary or steamapps that is a link (to this VM's C:\Windows, say) would have
    # Steam's service work there. Such a disk is never added.
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
    # Steam rewrites the file when it exits, so an open Steam is asked to close (in the signed-in user's session,
    # where it runs), the library is added, and Steam opens again minimized. A game in progress keeps it open: then
    # nothing is touched.
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
    $r = Invoke-Command -VMName $VMName -Credential $Credential -ErrorAction Stop -ScriptBlock $script:GuestSharedDiskSetup -ArgumentList $Disk['label'], $Disk['purpose']
    # Only primitive values from the guest are used.
    $status = [string]$r['status']
    $letter = [string]$r['letter']
    if ($letter -notmatch '^[A-Z]$') { $letter = '' }
    switch ($status) {
        'ready' { Write-Step "Disco '$($Disk['name'])' en $letter`: dentro de la VM" }
        default { Write-Warning "La VM no muestra el disco '$($Disk['name'])' todavía." }
    }
    switch ([string]$r['steam']) {
        'registered' { Write-Step "Biblioteca de Steam en $letter`:\SteamLibrary" }
        'link' { Write-Warning "El disco '$($Disk['name'])' tiene un enlace en SteamLibrary (lo dejó otra máquina); no se suma a Steam. Revísalo antes de usarlo." }
        'running' { Write-Warning "Steam no se pudo cerrar en la VM (¿hay un juego abierto?): ciérralo y vuelve a conectar el disco para sumar $letter`:\SteamLibrary a sus bibliotecas." }
    }
    $letter
}

# Folders that never go into a shared disk (a guest reads it): GpuVM's own (VM disks, templates, secrets), Windows,
# and anything that contains them, such as a drive root or the Users folder. A folder inside Program Files (Steam's
# own library) is fine.
function Assert-ImportableFolder {
    param([Parameter(Mandatory)][string]$Path)
    $source = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($source.Length -le 3) { throw 'No se puede importar una unidad entera; elige una carpeta.' }
    $inside = @((Get-GpuVMDefaultRoot), $script:DataRoot, $env:SystemRoot)
    $notAbove = @($inside + [Environment]::GetFolderPath('ProgramFiles') + ${env:ProgramFiles(x86)} + $env:ProgramData +
        (Split-Path ([Environment]::GetFolderPath('UserProfile')) -Parent)) | Where-Object { $_ }
    foreach ($protected in $notAbove) {
        $p = [IO.Path]::GetFullPath($protected).TrimEnd('\')
        $sourceAbove = "$p\".StartsWith("$source\", [StringComparison]::OrdinalIgnoreCase)
        $sourceInside = $p -in $inside -and "$source\".StartsWith("$p\", [StringComparison]::OrdinalIgnoreCase)
        if ($sourceAbove -or $sourceInside) { throw "No se puede importar ${source}: contiene o está dentro de $p." }
    }
}

# Fails closed: any folder below Path that can't be listed (a guest can deny access to it) or any link at all stops
# the copy, since an unseen junction would send it out of the disk.
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
        catch { throw "No se pudo revisar $($dir.Substring($Root.Length)) en el disco; no se copia en él." }
        foreach ($entry in $entries) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "El disco tiene un enlace en $($entry.FullName.Substring($Root.Length)); no se copia en él."
            }
            if ($entry -is [IO.DirectoryInfo]) { $pending.Push($entry.FullName) }
        }
    }
}
