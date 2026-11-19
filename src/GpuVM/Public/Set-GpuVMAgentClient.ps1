function Set-GpuVMAgentClient {
    <#
    .SYNOPSIS
    Whether an MCP client (by name) may ask you to approve low-risk steps in its own window (elicitation; off by default).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$ClientApprovals
    )
    Invoke-AgentBroker -Command 'Set-GpuVMAgentClient' -Arguments (ConvertTo-AgentArguments $PSBoundParameters)
}
