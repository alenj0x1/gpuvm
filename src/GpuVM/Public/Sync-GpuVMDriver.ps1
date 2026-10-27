function Sync-GpuVMDriver {
    <#
    .SYNOPSIS
    Copies the GPU driver installed on the host to the guest. Use it after updating the NVIDIA driver.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        # If the VM is running, shut it down, sync and power it back on.
        [switch]$ShutdownIfRunning
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    if (-not $PSCmdlet.ShouldProcess($Name, 'Sincronizar driver de GPU')) { return }
    $wasRunning = (Get-VM -Name $Name).State -eq 'Running'
    if ($wasRunning -and $ShutdownIfRunning) {
        Write-Step 'Apagando'
        Stop-VM -Name $Name -Force
    }
    try {
        $gpu = @(Invoke-GpuVMBackend -Backend $state['backend'] -Operation SyncDriver -Arguments $Name, $state) |
            Where-Object { $_.PSObject.Properties['DriverVersion'] } | Select-Object -Last 1
        $state['gpu'] = [ordered]@{
            name          = $gpu.Name
            pnpDeviceId   = $gpu.PnpDeviceId
            driverVersion = $gpu.DriverVersion
            syncedAt      = (Get-Date).ToString('o')
        }
        Save-GpuVMState $state
    }
    finally {
        # Even if the copy fails, the VM returns to the state it was in.
        if ($wasRunning -and $ShutdownIfRunning) {
            Write-Step 'Encendiendo'
            Start-VM -Name $Name
        }
    }
    Get-GpuVM -Name $Name
}
