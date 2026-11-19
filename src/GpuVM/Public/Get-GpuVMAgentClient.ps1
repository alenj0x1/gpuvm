function Get-GpuVMAgentClient {
    <#
    .SYNOPSIS
    Agent sessions (one per MCP client): machine, task, state (working, paused, control, human, waiting, idle, stopped), budget and last steps.
    #>
    [CmdletBinding()]
    param(
        [string]$Connection
    )
    Invoke-AgentBroker -Command 'Get-GpuVMAgentClient' -Arguments (ConvertTo-AgentArguments $PSBoundParameters)
}
