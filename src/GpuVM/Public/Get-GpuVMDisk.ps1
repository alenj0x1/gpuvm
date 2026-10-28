function Get-GpuVMDisk {
    <#
    .SYNOPSIS
    The disks in the GpuVM folder: which VM uses each one, and which are free to reuse (Restore-GpuVM) or delete.
    #>
    [CmdletBinding()]
    param()
    Assert-Admin
    $root = Get-GpuVMDefaultRoot
    if (-not (Test-Path -LiteralPath $root)) { return }
    $usedBy = @{}
    foreach ($drive in Get-VM | Get-VMHardDiskDrive) {
        if ($drive.Path) { $usedBy[[IO.Path]::GetFullPath($drive.Path)] = $drive.VMName }
    }
    $names = @(Get-VM | ForEach-Object Name)
    $freeGB = [math]::Floor(([IO.DriveInfo]::new((Split-Path $root -Qualifier))).AvailableFreeSpace / 1GB)

    foreach ($dir in Get-ChildItem -LiteralPath $root -Directory) {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $dir.FullName 'Virtual Hard Disks') -Filter *.vhdx -File -ErrorAction SilentlyContinue) {
            $vhd = Get-VHD -Path $file.FullName -ErrorAction SilentlyContinue
            $statePath = Join-Path $dir.FullName 'gpuvm.json'
            $state = if (Test-Path -LiteralPath $statePath) { try { Read-JsonFile $statePath } catch { $null } }
            $vm = $usedBy[$file.FullName]
            [ordered]@{
                name       = $dir.Name
                path       = $file.FullName
                sizeGB     = if ($vhd) { [math]::Round($vhd.Size / 1GB) } else { 0 }
                fileGB     = [math]::Round($file.Length / 1GB, 1)
                type       = if ($vhd) { [string]$vhd.VhdType } else { $null }
                vm         = $vm
                restorable = -not $vm -and [bool]$state -and $dir.Name -notin $names
                profile    = if ($state) { $state['profile'] } else { $null }
                edition    = if ($state) { $state['edition'] } else { $null }
                createdAt  = if ($state) { $state['createdAt'] } else { $file.CreationTime.ToString('o') }
                hostFreeGB = $freeGB
            }
        }
    }
}
