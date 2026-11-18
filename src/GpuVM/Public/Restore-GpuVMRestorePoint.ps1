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
    $state = Get-GpuVMState -Name $Name
    if (-not $PSCmdlet.ShouldProcess($Name, "Volver al punto $Id")) { return }
    $restart = Stop-GpuVMForDisk -Name $Name -ShutdownIfRunning:$ShutdownIfRunning -Action 'volver a un punto de restauración'
    try {
        if ($SaveCurrent) { New-GpuVMRestorePointCore -Name $Name -State $state -Label 'Antes de volver' | Out-Null }
        $point = Restore-GpuVMRestorePointCore -Name $Name -State $state -Id $Id
    }
    finally {
        if ($restart) {
            Write-Step 'Encendiendo'
            try { Start-VM -Name $Name -ErrorAction Stop } catch { Write-Warning "No se pudo volver a encender ${Name}: $($_.Exception.Message)" }
        }
    }
    $point
}
