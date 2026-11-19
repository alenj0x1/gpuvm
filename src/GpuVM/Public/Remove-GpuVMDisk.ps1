function Remove-GpuVMDisk {
    <#
    .SYNOPSIS
    Deletes a disk that no VM uses, with its folder. Cannot be undone.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name)
    Assert-Admin
    $root = Get-GpuVMDefaultRoot
    $dir = Join-Path $root $Name
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "There's no disk called '$Name' in $root." }
    $inUse = Get-VM | Get-VMHardDiskDrive | Where-Object { $_.Path -and [IO.Path]::GetFullPath($_.Path).StartsWith("$dir\", [StringComparison]::OrdinalIgnoreCase) }
    if ($inUse) { throw "The VM '$($inUse[0].VMName)' uses the disk; delete the VM first." }
    # A registered VM keeps its configuration in that folder even with its disk detached.
    $owner = Get-VM | Where-Object { $_.Name -eq $Name -or ($_.ConfigurationLocation -and [IO.Path]::GetFullPath($_.ConfigurationLocation).StartsWith("$dir\", [StringComparison]::OrdinalIgnoreCase)) } | Select-Object -First 1
    if ($owner) { throw "The folder belongs to the VM '$($owner.Name)'; delete the VM first." }
    if ((Get-Item -LiteralPath $dir).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$dir is a link; it won't be deleted." }
    if (-not $PSCmdlet.ShouldProcess($dir, 'Delete the disk and its folder')) { return }
    Remove-Item -LiteralPath $dir -Recurse -Force
}
