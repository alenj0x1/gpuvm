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

# Copies the host driver into a mounted Windows (e.g. 'X:\').
# DriverStore folders go to HostDriverStore, which is where GPU-P looks for them inside the guest.
function Copy-GpuDriverToWindows {
    param(
        [Parameter(Mandatory)]$FileSet,
        [Parameter(Mandatory)][string]$WindowsRoot
    )
    # Copy to a staging folder first and only replace the previous one at the end:
    # if the copy fails halfway, the guest keeps the driver it had.
    $hostStore = Join-Path $WindowsRoot 'Windows\System32\HostDriverStore\FileRepository'
    $staging = "$hostStore.gpuvm-new"
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    foreach ($folder in $FileSet.DriverStoreFolders) {
        if (Test-Path -LiteralPath $folder) {
            Copy-Item -LiteralPath $folder -Destination $staging -Recurse -Force
        }
    }
    if (Test-Path -LiteralPath $hostStore) { Remove-Item -LiteralPath $hostStore -Recurse -Force }
    Rename-Item -LiteralPath $staging -NewName (Split-Path $hostStore -Leaf)
    $copied = 0
    foreach ($file in $FileSet.Files) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $target = Join-Path $WindowsRoot ($file.Substring(3))
        $dir = Split-Path $target -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item -LiteralPath $file -Destination $target -Force
        $copied++
    }
    [pscustomobject]@{ Folders = $FileSet.DriverStoreFolders.Count; Files = $copied }
}
