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
    $null = Resolve-GpuVMSettings -State $state -Override $Override
    $previous = Merge-Hashtable -Base $state['config']

    $wasRunning = (Get-VM -Name $Name).State -eq 'Running'
    if ($wasRunning) {
        $newMemory = if ($Override['vm'] -and $Override['vm']['memoryGB']) { $Override['vm']['memoryGB'] } else { $state['config']['vm']['memoryGB'] }
        $currentGB = (Get-VM -Name $Name).MemoryStartup / 1GB
        # Shutting down frees the VM's current memory, so it counts as available.
        Assert-FreeMemory -RequiredGB $newMemory -ExtraFreeGB $currentGB
        Write-Step 'Shutting down'
        Stop-VM -Name $Name -Force
    }
    try {
        Write-Step 'Applying'
        Set-GpuVM -Name $Name -Override $Override -Confirm:$false | Out-Null
    }
    finally {
        if ($wasRunning) {
            Write-Step 'Starting'
            try { Start-VM -Name $Name -ErrorAction Stop }
            catch {
                Write-Warning "The VM didn't turn on with the new settings ($($_.Exception.Message)); the previous ones were restored."
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
