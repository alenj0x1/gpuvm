function Get-GpuVMRestorePoint {
    <#
    .SYNOPSIS
    Lists a VM's restore points: id, name, date, the space each takes, which one the VM is on now, and how much
    the VM has written since.
    .EXAMPLE
    Get-GpuVMRestorePoint -Name win10
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name)
    Assert-Admin
    Get-GpuVMRestorePointView -State (Get-GpuVMState -Name $Name)
}
