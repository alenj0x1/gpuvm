function Get-GpuVMMonitor {
    <#
    .SYNOPSIS
    The monitors of this PC, left to right, to choose the one a VM opens on (Connect-GpuVM -Monitor).
    .EXAMPLE
    Get-GpuVMMonitor
    #>
    [CmdletBinding()]
    param()
    Get-HostMonitor
}
