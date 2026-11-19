function Set-GpuVMUse {
    <#
    .SYNOPSIS
    What a machine is for: 'agent' (GpuVM's agent works in it) or 'none' (back to a person's machine).

    .DESCRIPTION
    agent: network isolation on (the machine reaches the internet, never this PC or the LAN), the agent installed or
    refreshed (Install-GpuVMAgent, signing in as `agent` or the person's user per Set-GpuVMAgentUser). The agent
    keeps its own display (the virtual display alone, 1280x800 at least). A machine that is off keeps the use and
    gets the agent at the next Set-GpuVMUse while it runs (`agent.pending`).
    none: the agent is removed (its user, service and secret; the person's automatic sign-in comes back). Needs the
    person's confirmation (UAC) like any deletion.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('agent', 'none')][string]$Use
    )
    $ErrorActionPreference = 'Stop'
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    if ($Use -eq 'none') {
        if ($state['agent']) { Uninstall-GpuVMAgent -Name $Name | Out-Null }
        $state = Get-GpuVMState -Name $Name
        if ($state.Contains('use')) { $state.Remove('use') }
        Save-GpuVMState $state
        return [ordered]@{ name = $Name; use = 'none' }
    }

    $state['use'] = 'agent'
    # Isolation on: an explicit false (the person turned it off) goes back to the default, which is on.
    $network = $state['config']['vm']['network']
    if ($network -and $network.Contains('isolation') -and $network['isolation'] -eq $false) { $network['isolation'] = $true }
    $user = if ($state['agent'] -and $state['agent']['signInAs']) { $state['agent']['signInAs'] } else { 'agent' }
    Save-GpuVMState $state
    Update-GpuVMNetworkIsolation -Name $Name -State $state

    $vm = Get-VM -Name $Name -ErrorAction Stop
    if ($vm.State -ne 'Running') {
        $state = Get-GpuVMState -Name $Name
        if (-not $state['agent']) { $state['agent'] = [ordered]@{} }
        $state['agent']['pending'] = $true
        $state['agent']['signInAs'] = $user
        Save-GpuVMState $state
        Write-Warning "'$Name' is off: the agent is installed the next time this runs with the machine on."
        return [ordered]@{ name = $Name; use = 'agent'; pending = $true }
    }
    # The display is the agent's own business (0.3.3: the virtual display alone, 1280x800 at least, and never over a
    # viewer's), so nothing is set from here.
    $installed = Install-GpuVMAgent -Name $Name -User $user
    [ordered]@{ name = $Name; use = 'agent'; agent = $installed }
}
