function Remove-GpuVM {
    <#
    .SYNOPSIS
    Removes the VM from Hyper-V. With -DeleteDisk it also deletes its folder and disk (cannot be undone).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$DeleteDisk
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    $action = if ($DeleteDisk) { "Delete the VM and erase $($state['vmDir'])" } else { 'Delete the VM (the disk is kept)' }
    if (-not $PSCmdlet.ShouldProcess($Name, $action)) { return }
    Invoke-GpuVMBackend -Backend $state['backend'] -Operation Remove -Arguments $Name, $state, ([bool]$DeleteDisk)
}
