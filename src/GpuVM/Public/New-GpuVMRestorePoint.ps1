function New-GpuVMRestorePoint {
    <#
    .SYNOPSIS
    Saves a restore point of a stopped VM: its Windows as it is now, to go back to later with Restore-GpuVMRestorePoint.
    It takes a second and no space at first; what the VM writes afterwards is kept apart from the point.
    .EXAMPLE
    New-GpuVMRestorePoint -Name win10 -Label 'Antes de instalar el juego'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name,
        [ValidateLength(0, 60)][string]$Label,
        # Shuts the VM down cleanly first and starts it again afterwards.
        [switch]$ShutdownIfRunning
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    if ($state.Contains('ephemeral') -and $state['ephemeral']) { throw 'Una máquina desechable no guarda puntos de restauración.' }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Crear punto de restauración')) { return }
    $restart = Stop-GpuVMForDisk -Name $Name -ShutdownIfRunning:$ShutdownIfRunning -Action 'crear un punto de restauración'
    try { $point = New-GpuVMRestorePointCore -Name $Name -State $state -Label $Label }
    finally {
        if ($restart) {
            Write-Step 'Encendiendo'
            try { Start-VM -Name $Name -ErrorAction Stop } catch { Write-Warning "No se pudo volver a encender ${Name}: $($_.Exception.Message)" }
        }
    }
    $point
}
