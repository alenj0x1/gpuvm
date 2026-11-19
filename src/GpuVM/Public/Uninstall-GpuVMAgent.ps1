function Uninstall-GpuVMAgent {
    <#
    .SYNOPSIS
    Removes GpuVM's agent: inside the machine when it is running (guest\agent\install.ps1 -Uninstall), and always on
    this PC (its secret and registration), so no agent can connect for that machine any more.
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
            try { Invoke-Command -VMName $Name -Credential $credential -ErrorAction Stop -FilePath $install -ArgumentList $null, $true | Out-Null }
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
