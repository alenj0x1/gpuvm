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

# Windows 10 gives a starting GPU-P machine the partitionable GPU with the fewest running machines, a tie going to the
# first one listed, and can't be told which (labs/001). Empty machines on for a moment even the count so the machine's
# own GPU is the one it gets.
function Get-GpuFillCount {
    param([Parameter(Mandatory)][string]$Name)
    if (Test-GpuInstancePathSupport) { return 0 }
    $gpus = @(Get-PartitionableGpuList)
    if ($gpus.Count -ne 2) { return 0 }
    $match = try { [string](Get-GpuVMState -Name $Name)['config']['gpu']['match'] } catch { '' }
    $target = Get-HostGpu -Match $(if ($match) { $match } else { 'NVIDIA' }) | Select-Object -First 1
    if (-not $target -or -not ($gpus | Where-Object VendorId -eq $target.VendorId)) { return 0 }
    $running = @(Hyper-V\Get-VM | Where-Object { $_.Name -ne $Name -and $_.State -in 'Running', 'Paused' -and (Test-GpuPartitioned -Name $_.Name) }).Count
    if ($gpus[0].VendorId -eq $target.VendorId) { $running } else { $running + 1 }
}

function Invoke-WithGpuChoice {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Do)
    $count = try { Get-GpuFillCount -Name $Name } catch { 0 }
    if (-not $count) { return & $Do }
    $root = Join-Path $env:ProgramData 'GpuVM\gpu-fill'
    $made = [Collections.Generic.List[string]]::new()
    try {
        for ($i = 1; $i -le $count; $i++) {
            $fill = "GpuVM-gpu-fill-$i"
            if (Hyper-V\Get-VM -Name $fill -ErrorAction SilentlyContinue) { Hyper-V\Stop-VM -Name $fill -TurnOff -Force -ErrorAction SilentlyContinue; Hyper-V\Remove-VM -Name $fill -Force }
            $made.Add($fill)
            Hyper-V\New-VM -Name $fill -Generation 2 -MemoryStartupBytes 64MB -NoVHD -Path $root | Out-Null
            Hyper-V\Get-VMNetworkAdapter -VMName $fill | Hyper-V\Remove-VMNetworkAdapter
            Hyper-V\Set-VM -Name $fill -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing -AutomaticStopAction TurnOff
            Hyper-V\Add-VMGpuPartitionAdapter -VMName $fill
            Hyper-V\Start-VM -Name $fill
        }
        Write-PowerLog "$Name started with $count empty machine(s) on the other GPU"
        & $Do
        # Turned off once the machine is up: a GPU machine changing power during another's boot can hang it (GpuPower.ps1).
        $deadline = (Get-Date).AddSeconds($script:GpuPowerUpSec)
        while ((Get-Date) -lt $deadline -and (Hyper-V\Get-VM -Name $Name).State -eq 'Running' -and -not (Test-GuestHeartbeat -Name $Name)) { Start-Sleep -Seconds 1 }
    }
    finally {
        foreach ($fill in $made) {
            try { Hyper-V\Stop-VM -Name $fill -TurnOff -Force -ErrorAction Stop; Hyper-V\Remove-VM -Name $fill -Force -ErrorAction Stop }
            catch { Write-PowerLog "couldn't remove $fill`: $($_.Exception.Message)" }
        }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Win32_PnPSignedDriverCIMDataFile sometimes fails with "Shutting down": retried, then built from the .inf.
function Get-GpuDriverFileSet {
    param(
        [Parameter(Mandatory)][string]$PnpDeviceId,
        [string]$DriverVersion
    )
    $cached = if ($DriverVersion) { Read-GpuDriverFileSetCache -PnpDeviceId $PnpDeviceId -DriverVersion $DriverVersion }
    if ($cached) { return $cached }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $set = Get-GpuDriverFileSetFromWmi -PnpDeviceId $PnpDeviceId
            if ($set.DriverStoreFolders.Count) {
                if ($DriverVersion) { Save-GpuDriverFileSetCache -PnpDeviceId $PnpDeviceId -DriverVersion $DriverVersion -Set $set }
                return $set
            }
        }
        catch {
            Write-Verbose "WMI failed (attempt $attempt): $_"
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds 5 }
    }
    Write-Warning 'WMI didn''t return the driver files; using the fallback method based on the .inf.'
    Get-GpuDriverFileSetFromInf -PnpDeviceId $PnpDeviceId
}

# It decides what is copied from the host into a VM: only paths still under the host's driver folders are accepted.
function Read-GpuDriverFileSetCache {
    param([string]$PnpDeviceId, [string]$DriverVersion)
    $path = Get-DataPath 'gpu-driver-files.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $entry = try { Read-JsonFile $path } catch { return $null }
    if ($entry['pnpDeviceId'] -ne $PnpDeviceId -or $entry['driverVersion'] -ne $DriverVersion) { return $null }
    $windows = [IO.Path]::GetFullPath($env:windir).TrimEnd('\') + '\'
    $store = Join-Path $windows 'System32\DriverStore\FileRepository\'
    $folders = @($entry['driverStoreFolders'])
    $files = @($entry['files'])
    if (-not $folders.Count) { return $null }
    foreach ($f in $folders) {
        if (-not $f -or [IO.Path]::GetFullPath($f) -ne $f -or -not $f.StartsWith($store, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $f -PathType Container)) { return $null }
    }
    foreach ($f in $files) {
        if (-not $f -or [IO.Path]::GetFullPath($f) -ne $f -or -not $f.StartsWith($windows, [StringComparison]::OrdinalIgnoreCase) -or
            $f.StartsWith((Join-Path $windows 'INF\'), [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $f -PathType Leaf)) { return $null }
    }
    [pscustomobject]@{ DriverStoreFolders = $folders; Files = $files }
}

function Save-GpuDriverFileSetCache {
    param([string]$PnpDeviceId, [string]$DriverVersion, $Set)
    try {
        Write-JsonFile -Path (Get-DataPath 'gpu-driver-files.json') -Data ([ordered]@{
                pnpDeviceId = $PnpDeviceId; driverVersion = $DriverVersion
                driverStoreFolders = @($Set.DriverStoreFolders); files = @($Set.Files)
            })
    }
    catch { Write-Verbose "Couldn't remember the driver's file list: $_" }
}

function Get-GpuDriverFileSetFromInf {
    param([Parameter(Mandatory)][string]$PnpDeviceId)
    $infName = (Get-PnpDeviceProperty -InstanceId $PnpDeviceId -KeyName DEVPKEY_Device_DriverInfPath).Data
    $infPath = Join-Path $env:windir "INF\$infName"
    if (-not $infName -or -not (Test-Path $infPath)) { throw "The driver's .inf for $PnpDeviceId wasn't found." }
    $infHash = (Get-FileHash $infPath).Hash

    $repository = Join-Path $env:windir 'System32\DriverStore\FileRepository'
    $folder = Get-ChildItem $repository -Directory |
        Where-Object { Get-ChildItem $_.FullName -Filter *.inf -File | Where-Object { (Get-FileHash $_.FullName).Hash -eq $infHash } } |
        Select-Object -First 1
    if (-not $folder) { throw "The driver's folder ($infName) wasn't found in the DriverStore." }

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
                [void]$files.Add($path)
            }
        }

    [pscustomobject]@{
        DriverStoreFolders = @($folders)
        Files              = @($files)
    }
}

# The guest could plant a junction (System32 -> the host's C:\Windows): every existing component below $Root must be plain.
function Assert-NoReparsePoint {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not $full.StartsWith("$rootFull\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "The path $full is outside the VM's disk; nothing is written there."
    }
    $current = $rootFull
    foreach ($part in $full.Substring($rootFull.Length + 1).Split('\')) {
        $current = Join-Path $current $part
        # GetAttributes does not follow links: it describes the link itself, even a dangling one.
        $attributes = try { [IO.File]::GetAttributes($current) }
        catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] { $null }
        if ($null -eq $attributes) { return }
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "The VM's disk has a link at $current; nothing is written through it so nothing lands outside the VM."
        }
    }
}

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
    foreach ($path in @($hostStore, $staging) + $looseFiles.Target) { Assert-NoReparsePoint -Root $WindowsRoot -Path $path }

    # Staged first: if the copy fails halfway, the guest keeps the driver it had.
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
