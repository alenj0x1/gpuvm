function New-GpuVMRestorePoint {
    <#
    .SYNOPSIS
    Saves a restore point of a stopped VM: its Windows as it is now, to go back to later with Restore-GpuVMRestorePoint.
    It takes a second and no space at first; what the VM writes afterwards is kept apart from the point.
    .EXAMPLE
    New-GpuVMRestorePoint -Name win10 -Label 'Before installing the game'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name,
        [ValidateLength(0, 60)][string]$Label,
        # Shuts the VM down cleanly first and starts it again afterwards.
        [switch]$ShutdownIfRunning
    )
    Assert-Admin
    Assert-HyperVMachine -Name $Name -What 'Restore points'
    $state = Get-GpuVMState -Name $Name
    Assert-GpuVMNotDisposable -State $state -Action 'keep restore points'
    if (-not $PSCmdlet.ShouldProcess($Name, 'Create restore point')) { return }
    $restart = Stop-GpuVMForDisk -Name $Name -ShutdownIfRunning:$ShutdownIfRunning -Action 'create a restore point'
    try { $point = New-GpuVMRestorePointCore -Name $Name -State $state -Label $Label }
    finally {
        if ($restart) {
            Write-Step 'Starting'
            try { Start-VM -Name $Name -ErrorAction Stop } catch { Write-Warning "Couldn't turn ${Name} back on: $($_.Exception.Message)" }
        }
    }
    $point
}
