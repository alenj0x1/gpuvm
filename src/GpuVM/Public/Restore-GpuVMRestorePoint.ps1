function Restore-GpuVMRestorePoint {
    <#
    .SYNOPSIS
    Puts a stopped VM's Windows back as it was at a restore point. What changed since the point it is on now is lost,
    unless -SaveCurrent keeps it as a new point first. The VM's settings (processors, memory, GPU) don't change.
    .EXAMPLE
    Restore-GpuVMRestorePoint -Name win10 -Id 20261118-101500-a1b2 -SaveCurrent
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name,
        [Parameter(Mandatory)][ValidatePattern('^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$')][string]$Id,
        # Saves how the VM is now as a point before going back.
        [switch]$SaveCurrent,
        [switch]$ShutdownIfRunning
    )
    Assert-Admin
    Assert-HyperVMachine -Name $Name -What 'Restore points'
    $state = Get-GpuVMState -Name $Name
    Assert-GpuVMNotDisposable -State $state -Action 'go back to a restore point'
    if (-not $PSCmdlet.ShouldProcess($Name, "Go back to the point $Id")) { return }
    $restart = Stop-GpuVMForDisk -Name $Name -ShutdownIfRunning:$ShutdownIfRunning -Action 'go back to a restore point'
    try {
        if ($SaveCurrent) { New-GpuVMRestorePointCore -Name $Name -State $state -Label 'Before going back' | Out-Null }
        $point = Restore-GpuVMRestorePointCore -Name $Name -State $state -Id $Id
    }
    finally {
        if ($restart) {
            Write-Step 'Starting'
            try { Start-VM -Name $Name -ErrorAction Stop } catch { Write-Warning "Couldn't turn ${Name} back on: $($_.Exception.Message)" }
        }
    }
    $point
}
