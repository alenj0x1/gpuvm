function Get-GpuVMAgentOffer {
    <#
    .SYNOPSIS
    Files offered from machines' Outbox and their state (pending, approved, declined, failed).
    #>
    [CmdletBinding()]
    param(
        [string]$Id,
        [string]$Name
    )
    Invoke-AgentBroker -Command 'Get-GpuVMAgentOffer' -Arguments (ConvertTo-AgentArguments $PSBoundParameters)
}
