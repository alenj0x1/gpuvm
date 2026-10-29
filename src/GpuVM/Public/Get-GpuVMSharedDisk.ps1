function Get-GpuVMSharedDisk {
    <#
    .SYNOPSIS
    The shared disks: their size, what they are for and the VM each one is attached to.
    #>
    [CmdletBinding()]
    param()
    Assert-Admin
    $root = Get-SharedDiskRoot
    if (-not (Test-Path -LiteralPath $root)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $root -Filter *.vhdx -File | Where-Object { $_.BaseName -match '^[\w-]{1,40}$' }) {
        $disk = Read-SharedDisk -Name $file.BaseName
        $vhd = Get-VHD -Path $file.FullName -ErrorAction SilentlyContinue
        $attachment = Get-SharedDiskAttachment -Path $file.FullName
        [ordered]@{
            name      = $disk['name']
            purpose   = $disk['purpose']
            sizeGB    = if ($vhd) { [math]::Round($vhd.Size / 1GB) } else { 0 }
            fileGB    = [math]::Round($file.Length / 1GB, 1)
            vm        = if ($attachment) { $attachment.VMName } else { $null }
            # Moving it from another machine only works while that one is off.
            vmRunning = [bool]($attachment -and (Get-VM -Name $attachment.VMName).State -ne 'Off')
            createdAt = if ($disk.Contains('createdAt')) { $disk['createdAt'] } else { $file.CreationTime.ToString('o') }
        }
    }
}
