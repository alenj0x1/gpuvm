function Get-HostGpu {
    param([string]$Match = 'NVIDIA')
    Get-CimInstance Win32_VideoController |
        Where-Object { $_.Name -like "*$Match*" } |
        ForEach-Object {
            [pscustomobject]@{
                Name          = $_.Name
                DriverVersion = $_.DriverVersion
                PnpDeviceId   = $_.PNPDeviceID
                VendorId      = if ($_.PNPDeviceID -match 'VEN_([0-9A-F]{4})') { $Matches[1] } else { $null }
            }
        }
}

# Windows 10 exposes Get-VMPartitionableGpu; Windows 11 renamed it to Get-VMHostPartitionableGpu.
function Get-PartitionableGpuList {
    $cmd = Get-Command Get-VMHostPartitionableGpu, Get-VMPartitionableGpu -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return @() }
    @(& $cmd.Name | ForEach-Object {
        [pscustomobject]@{
            InstancePath   = $_.Name
            VendorId       = if ($_.Name -match 'VEN_([0-9A-F]{4})') { $Matches[1] } else { $null }
            PartitionCount = $_.PartitionCount
        }
    })
}

# On Windows 10 Add-VMGpuPartitionAdapter cannot pick the GPU; since Windows 11 it accepts -InstancePath.
function Test-GpuInstancePathSupport {
    (Get-Command Add-VMGpuPartitionAdapter -ErrorAction SilentlyContinue).Parameters.ContainsKey('InstancePath')
}

# Lists the files installed by the GPU driver, split into DriverStore folders and loose files.
# Uses WMI (Win32_PnPSignedDriverCIMDataFile, ~30 s); that provider sometimes fails with "Shutting down",
# so it is retried and, if it keeps failing, the list is built from the driver's .inf.
function Get-GpuDriverFileSet {
    param([Parameter(Mandatory)][string]$PnpDeviceId)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $set = Get-GpuDriverFileSetFromWmi -PnpDeviceId $PnpDeviceId
            if ($set.DriverStoreFolders.Count) { return $set }
        }
        catch {
            Write-Verbose "WMI falló (intento $attempt): $_"
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds 5 }
    }
    Write-Warning 'WMI no devolvió los archivos del driver; se usa el método alternativo basado en el .inf.'
    Get-GpuDriverFileSetFromInf -PnpDeviceId $PnpDeviceId
}

# The DriverStore folder is the one containing an identical copy of the device's oemNN.inf.
# Loose files are the ones the driver copied to System32/SysWOW64 with the same name as in that folder.
function Get-GpuDriverFileSetFromInf {
    param([Parameter(Mandatory)][string]$PnpDeviceId)
    $infName = (Get-PnpDeviceProperty -InstanceId $PnpDeviceId -KeyName DEVPKEY_Device_DriverInfPath).Data
    $infPath = Join-Path $env:windir "INF\$infName"
    if (-not $infName -or -not (Test-Path $infPath)) { throw "No se encontró el .inf del driver de $PnpDeviceId." }
    $infHash = (Get-FileHash $infPath).Hash

    $repository = Join-Path $env:windir 'System32\DriverStore\FileRepository'
    $folder = Get-ChildItem $repository -Directory |
        Where-Object { Get-ChildItem $_.FullName -Filter *.inf -File | Where-Object { (Get-FileHash $_.FullName).Hash -eq $infHash } } |
        Select-Object -First 1
    if (-not $folder) { throw "No se encontró en el DriverStore la carpeta del driver ($infName)." }

    # DriverStore names plus the .inf CopyFiles targets ("target,source"), because some are renamed when copied.
    $names = @(Get-ChildItem $folder.FullName -Recurse -File | ForEach-Object Name)
    $names += Get-Content $infPath | ForEach-Object {
        if ($_ -match '^\s*([\w.\-]+\.(?:dll|exe|so(?:\.\d+)?|bin|txt))\s*,') { $Matches[1] }
    }
    $names = $names | Sort-Object -Unique
    $dirs = 'System32', 'SysWOW64', 'System32\lxss\lib', 'System32\drivers\NVIDIA Corporation', 'System32\drivers\NVIDIA Corporation\drs'
    $files = foreach ($dir in $dirs) {
        foreach ($name in $names) {
            $candidate = Join-Path $env:windir "$dir\$name"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidate.ToLowerInvariant() }
        }
    }
    [pscustomobject]@{
        DriverStoreFolders = @($folder.FullName.ToLowerInvariant())
        Files              = @($files)
    }
}

function Get-GpuDriverFileSetFromWmi {
    param([Parameter(Mandatory)][string]$PnpDeviceId)
    $driverStore = 'c:\windows\system32\driverstore\filerepository\'
    $folders = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    Get-CimInstance Win32_PnPSignedDriverCIMDataFile -ErrorAction Stop |
        Where-Object { $_.Antecedent.DeviceID -eq $PnpDeviceId } |
        ForEach-Object {
            $path = $_.Dependent.Name
            if ($path.StartsWith($driverStore, [StringComparison]::OrdinalIgnoreCase)) {
                [void]$folders.Add(($path.Split('\')[0..5] -join '\'))
            }
            elseif (-not $path.StartsWith('c:\windows\inf\', [StringComparison]::OrdinalIgnoreCase)) {
                # The .inf registers the driver on the host; the guest does not install it, it only uses the binaries.
                [void]$files.Add($path)
            }
        }

    [pscustomobject]@{
        DriverStoreFolders = @($folders)
        Files              = @($files)
    }
}

# The guest's disk is written to as administrator, so a junction or symlink planted by the guest
# (e.g. System32 -> the host's C:\Windows) would redirect the write to the host. Each component of
# $Path below $Root that exists must be a plain file or folder; the root itself (a mount point) is not checked.
function Assert-NoReparsePoint {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not $full.StartsWith("$rootFull\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "La ruta $full queda fuera del disco de la VM; no se escribe."
    }
    $current = $rootFull
    foreach ($part in $full.Substring($rootFull.Length + 1).Split('\')) {
        $current = Join-Path $current $part
        # GetAttributes does not follow links: it describes the link itself, even a dangling one.
        $attributes = try { [IO.File]::GetAttributes($current) }
        catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] { $null }
        # Nothing exists from here down: it will be created as plain folders.
        if ($null -eq $attributes) { return }
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "El disco de la VM tiene un enlace en $current; no se copia el driver para no escribir fuera de la VM."
        }
    }
}

# Deletes a folder of the guest's disk without following the links inside it: a link is removed, not its target.
function Remove-GuestDirectory {
    param([Parameter(Mandatory)][string]$Path)
    foreach ($entry in [IO.DirectoryInfo]::new($Path).EnumerateFileSystemInfos()) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            if ($entry -is [IO.DirectoryInfo]) { [IO.Directory]::Delete($entry.FullName, $false) } else { [IO.File]::Delete($entry.FullName) }
        }
        elseif ($entry -is [IO.DirectoryInfo]) { Remove-GuestDirectory -Path $entry.FullName }
        else {
            $entry.Attributes = [IO.FileAttributes]::Normal
            $entry.Delete()
        }
    }
    [IO.Directory]::Delete($Path, $false)
}

# Copies the host driver into a mounted Windows (e.g. 'X:\').
# DriverStore folders go to HostDriverStore, which is where GPU-P looks for them inside the guest.
function Copy-GpuDriverToWindows {
    param(
        [Parameter(Mandatory)]$FileSet,
        [Parameter(Mandatory)][string]$WindowsRoot
    )
    $hostStore = Join-Path $WindowsRoot 'Windows\System32\HostDriverStore\FileRepository'
    $staging = "$hostStore.gpuvm-new"
    $looseFiles = @(foreach ($file in $FileSet.Files) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        [pscustomobject]@{ Source = $file; Target = Join-Path $WindowsRoot ($file.Substring(3)) }
    })
    # Every destination is checked before writing anything, and again right before each write.
    foreach ($path in @($hostStore, $staging) + $looseFiles.Target) { Assert-NoReparsePoint -Root $WindowsRoot -Path $path }

    # Copy to a staging folder first and only replace the previous one at the end:
    # if the copy fails halfway, the guest keeps the driver it had.
    if (Test-Path -LiteralPath $staging) { Remove-GuestDirectory -Path $staging }
    Assert-NoReparsePoint -Root $WindowsRoot -Path $staging
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    foreach ($folder in $FileSet.DriverStoreFolders) {
        if (Test-Path -LiteralPath $folder) {
            # The source is the host's DriverStore and the destination a folder just created: nothing of the guest's is followed.
            Copy-Item -LiteralPath $folder -Destination $staging -Recurse -Force
        }
    }
    Assert-NoReparsePoint -Root $WindowsRoot -Path $hostStore
    if (Test-Path -LiteralPath $hostStore) { Remove-GuestDirectory -Path $hostStore }
    Rename-Item -LiteralPath $staging -NewName (Split-Path $hostStore -Leaf)
    $copied = 0
    foreach ($file in $looseFiles) {
        Assert-NoReparsePoint -Root $WindowsRoot -Path $file.Target
        $dir = Split-Path $file.Target -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item -LiteralPath $file.Source -Destination $file.Target -Force
        $copied++
    }
    [pscustomobject]@{ Folders = $FileSet.DriverStoreFolders.Count; Files = $copied }
}
