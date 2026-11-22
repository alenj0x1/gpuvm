function Uninstall-GpuVMAgent {
    <#
    .SYNOPSIS
    Removes GpuVM's agent: inside the machine when it is running (guest\agent\install.ps1 -Uninstall -RemoveUser:
    service, files, the `agent` user, and the person's automatic sign-in comes back), and always on this PC (its
    secret and registration), so no agent can connect for that machine any more. The machine stops being an agent
    machine.

    .DESCRIPTION
    While `agent` is signed in its profile can't be deleted: Windows restarts (the person's own sign-in is back), and
    the removal runs again to delete the user and its profile. If that can't happen now (the machine doesn't come
    back in time), it is finished the next time the machine is opened (Connect-GpuVM).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $ErrorActionPreference = 'Stop'
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    $vm = Get-VM -Name $Name -ErrorAction Stop
    $pending = $false
    if ($vm.State -eq 'Running') {
        $credential = Get-GpuVMGuestCredential -State $state
        if ($credential -and (Test-Path -LiteralPath (Get-RepoPath 'guest\agent\install.ps1'))) {
            Write-Step 'Removing the agent from the machine'
            try {
                $boot = try { Get-GuestBootTime -Name $Name -Credential $credential } catch { '' }
                $r = Invoke-GuestAgentRemoval -Name $Name -Credential $credential
                if ($r -and $r.PSObject.Properties['rebootNeeded'] -and $r.rebootNeeded) {
                    Write-Step 'Restarting Windows in the machine to finish'
                    Invoke-Command -VMName $Name -Credential $credential -ScriptBlock { Restart-Computer -Force } -ErrorAction SilentlyContinue
                    $pending = -not (Complete-GuestAgentRemoval -Name $Name -Credential $credential -BootBefore $boot)
                }
            }
            catch {
                Write-Warning "Couldn't remove the agent inside '$Name': $($_.Exception.Message)"
                $pending = $true
            }
        }
    }
    else {
        Write-Warning "'$Name' is off: the agent stays inside it, but it can't connect to GpuVM any more. It is removed the next time the machine is opened."
        $pending = $true
    }
    Remove-GpuVMAgentRegistration -VMId $vm.Id.Guid
    $state = Get-GpuVMState -Name $Name
    if ($state.Contains('agent')) { $state.Remove('agent') }
    if ($state.Contains('use')) { $state.Remove('use') }
    if ($pending) { $state['agentRemovalPending'] = $true } elseif ($state.Contains('agentRemovalPending')) { $state.Remove('agentRemovalPending') }
    Save-GpuVMState $state
    [ordered]@{ name = $Name; removalPending = $pending }
}
