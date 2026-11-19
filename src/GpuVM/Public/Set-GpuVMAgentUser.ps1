function Set-GpuVMAgentUser {
    <#
    .SYNOPSIS
    Who Windows signs in as on an agent machine: the agent's own standard user `agent` (default) or the person's own
    user as it was configured before. Re-runs the agent's installer (fast: same version), which also gives `agent` a
    new password; Windows restarts in the machine when the sign-in changes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('agent', 'own')][string]$User
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    if (-not $state['agent']) { throw "'$Name' doesn't have GpuVM's agent. Set its use to Agent first." }
    if ((Get-VM -Name $Name -ErrorAction Stop).State -ne 'Running') {
        $state['agent']['signInAs'] = $User
        $state['agent']['pending'] = $true
        Save-GpuVMState $state
        Write-Warning "'$Name' is off: the change is made the next time the agent is installed with the machine on."
        return [ordered]@{ name = $Name; user = $User; pending = $true }
    }
    $installed = Install-GpuVMAgent -Name $Name -User $User
    [ordered]@{ name = $Name; user = $User; restarted = $installed.restarted }
}
