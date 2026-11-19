function Uninstall-GpuVMAgent {
    <#
    .SYNOPSIS
    Removes GpuVM's agent: inside the machine when it is running (guest\agent\install.ps1 -Uninstall -RemoveUser:
    service, files, the `agent` user, and the person's automatic sign-in comes back), and always on this PC (its
    secret and registration), so no agent can connect for that machine any more.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    $vm = Get-VM -Name $Name -ErrorAction Stop
    if ($vm.State -eq 'Running') {
        $credential = Get-GpuVMGuestCredential -State $state
        $install = Get-RepoPath 'guest\agent\install.ps1'
        if ($credential -and (Test-Path -LiteralPath $install)) {
            Write-Step 'Removing the agent from the machine'
            # The script's text runs with named arguments (switches never bind by position; guests are Restricted).
            $code = Get-Content -Raw -LiteralPath $install
            try {
                $r = Invoke-Command -VMName $Name -Credential $credential -ErrorAction Stop -ArgumentList $code -ScriptBlock {
                    param($code) & ([scriptblock]::Create($code)) -Uninstall -RemoveUser
                } | Select-Object -Last 1
                if ($r -and $r.PSObject.Properties['rebootNeeded'] -and $r.rebootNeeded) {
                    Invoke-Command -VMName $Name -Credential $credential -ScriptBlock { Restart-Computer -Force } -ErrorAction SilentlyContinue
                }
            }
            catch { Write-Warning "Couldn't remove the agent inside '$Name': $($_.Exception.Message)" }
        }
    }
    else {
        Write-Warning "'$Name' is off: the agent stays inside it, but it can't connect to GpuVM any more."
    }
    Remove-GpuVMAgentRegistration -VMId $vm.Id.Guid
    if ($state.Contains('agent')) {
        $state.Remove('agent')
        Save-GpuVMState $state
    }
    [ordered]@{ name = $Name }
}
