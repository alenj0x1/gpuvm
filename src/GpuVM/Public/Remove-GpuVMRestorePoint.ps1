function Remove-GpuVMRestorePoint {
    <#
    .SYNOPSIS
    Deletes a restore point. The VM keeps everything it has now: what was written after the point is merged into it.
    .EXAMPLE
    Remove-GpuVMRestorePoint -Name win10 -Id 20261118-101500-a1b2
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name,
        [Parameter(Mandatory)][ValidatePattern('^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$')][string]$Id,
        [switch]$ShutdownIfRunning
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    if (-not $PSCmdlet.ShouldProcess($Name, "Borrar el punto $Id")) { return }
    # A point nothing sits on is deleted with the VM on; merging into one needs it off.
    $restart = $false
    $pointPath = Get-RestorePointPath -State $state -Id $Id
    if ((Test-Path -LiteralPath $pointPath) -and @(Get-RestorePointChild -State $state -Path $pointPath).Count) {
        $restart = Stop-GpuVMForDisk -Name $Name -ShutdownIfRunning:$ShutdownIfRunning -Action 'borrar este punto de restauración'
    }
    try { Remove-GpuVMRestorePointCore -Name $Name -State $state -Id $Id }
    finally {
        if ($restart) {
            Write-Step 'Encendiendo'
            try { Start-VM -Name $Name -ErrorAction Stop } catch { Write-Warning "No se pudo volver a encender ${Name}: $($_.Exception.Message)" }
        }
    }
}
