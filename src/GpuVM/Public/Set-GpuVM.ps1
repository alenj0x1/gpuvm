function Set-GpuVM {
    <#
    .SYNOPSIS
    Adjusts an existing, stopped VM. Without -Profile it starts from its current configuration and only changes
    what the override sets; with -Profile it switches profile but keeps the disk, folder and Moonlight preferences.
    .EXAMPLE
    Set-GpuVM -Name win11 -Override @{ vm = @{ cpu = @{ count = 10 } } }
    Set-GpuVM -Name win11 -Profile max-performance
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidatePattern('^[\w-]+$')][string]$Profile,
        [hashtable]$Override
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    $config = Resolve-GpuVMSettings -State $state -Profile $Profile -Override $Override
    $profileName = $config['name']

    if (-not $PSCmdlet.ShouldProcess($Name, "Aplicar perfil $profileName")) { return }
    Invoke-GpuVMBackend -Backend $state['backend'] -Operation Apply -Arguments $Name, $config
    $state['profile'] = $profileName
    $state['config'] = $config
    $state['updatedAt'] = (Get-Date).ToString('o')
    Save-GpuVMState $state
    Get-GpuVM -Name $Name
}

# Computes and validates the new configuration without touching the VM, so it can be validated before shutting it down.
function Resolve-GpuVMSettings {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [string]$Profile,
        [System.Collections.IDictionary]$Override
    )
    if ($Profile) {
        $config = Resolve-GpuVMProfile -Name $Profile -Override $Override
        # What was decided when creating the VM, or by the user, does not change with the profile.
        $config['vm']['disk'] = $State['config']['vm']['disk']
        $config['vm']['root'] = $State['config']['vm']['root']
        if ($State['config']['streaming'] -and $config['streaming']) {
            $config['streaming']['client'] = $State['config']['streaming']['client']
            if ($State['config']['streaming'].Contains('captureMode')) { $config['streaming']['captureMode'] = $State['config']['streaming']['captureMode'] }
        }
    }
    else {
        $config = Merge-Hashtable -Base $State['config'] -Override $Override
    }

    $cs = Get-CimInstance Win32_ComputerSystem
    $logical = [int](Get-CimInstance Win32_Processor | Select-Object -First 1).NumberOfLogicalProcessors
    $problems = Test-GpuVMProfileData -Config $config -HostLogicalProcessors $logical -HostMemoryGB ($cs.TotalPhysicalMemory / 1GB)
    if ($problems.Count) { throw ($problems -join ' ') }
    # A disk only grows; refusing here keeps the saved size equal to the real one.
    $current = [int]$State['config']['vm']['disk']['sizeGB']
    if ([int]$config['vm']['disk']['sizeGB'] -lt $current) { throw "El disco mide $current GB y no se puede reducir." }
    $config
}
