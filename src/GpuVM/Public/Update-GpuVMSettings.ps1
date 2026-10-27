function Update-GpuVMSettings {
    <#
    .SYNOPSIS
    Applies processor, memory or GPU settings to a VM even while running: validates, shuts it down, applies and powers it back on.
    If it cannot power back on (e.g. not enough free memory), it restores the previous configuration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Override
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    # Validate before shutting down: if the change is not possible, the VM stays as it was.
    $null = Resolve-GpuVMSettings -State $state -Override $Override
    $previous = Merge-Hashtable -Base $state['config']

    $wasRunning = (Get-VM -Name $Name).State -eq 'Running'
    if ($wasRunning) {
        $newMemory = if ($Override['vm'] -and $Override['vm']['memoryGB']) { $Override['vm']['memoryGB'] } else { $state['config']['vm']['memoryGB'] }
        $currentGB = (Get-VM -Name $Name).MemoryStartup / 1GB
        # Shutting down frees the VM's current memory, so it counts as available.
        Assert-FreeMemory -RequiredGB $newMemory -ExtraFreeGB $currentGB
        Write-Step 'Apagando'
        Stop-VM -Name $Name -Force
    }
    try {
        Write-Step 'Aplicando'
        Set-GpuVM -Name $Name -Override $Override -Confirm:$false | Out-Null
    }
    finally {
        if ($wasRunning) {
            Write-Step 'Encendiendo'
            try { Start-VM -Name $Name -ErrorAction Stop }
            catch {
                Write-Warning "La VM no encendió con los ajustes nuevos ($($_.Exception.Message)); se restauraron los anteriores."
                Invoke-GpuVMBackend -Backend $state['backend'] -Operation Apply -Arguments $Name, $previous
                $restored = Get-GpuVMState -Name $Name
                $restored['config'] = $previous
                Save-GpuVMState $restored
                Start-VM -Name $Name
            }
        }
    }
    [ordered]@{ name = $Name; state = (Get-VM -Name $Name).State.ToString() }
}
