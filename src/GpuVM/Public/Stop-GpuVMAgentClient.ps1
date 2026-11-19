function Stop-GpuVMAgentClient {
    <#
    .SYNOPSIS
    Kill switch: stops one agent session (or all), cancels what it is doing and frees its machines.
    #>
    [CmdletBinding()]
    param(
        [string]$Connection,
        [switch]$All
    )
    Invoke-AgentBroker -Command 'Stop-GpuVMAgentClient' -Arguments (ConvertTo-AgentArguments $PSBoundParameters)
}
