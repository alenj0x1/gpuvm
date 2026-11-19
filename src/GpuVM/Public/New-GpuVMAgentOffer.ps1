function New-GpuVMAgentOffer {
    <#
    .SYNOPSIS
    Offers a file of the agent's Desktop\Outbox to the person; it leaves the machine only after Resolve-GpuVMAgentOffer -Accept $true.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [string]$Note
    )
    Invoke-AgentBroker -Command 'New-GpuVMAgentOffer' -Arguments (ConvertTo-AgentArguments $PSBoundParameters)
}
