function Get-GpuVMAgentCapture {
    <#
    .SYNOPSIS
    The screenshot of one step of an agent session (as base64), while it is among the last 10 kept.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Connection,
        [Parameter(Mandatory)][long]$Action
    )
    Invoke-AgentBroker -Command 'Get-GpuVMAgentCapture' -Arguments (ConvertTo-AgentArguments $PSBoundParameters)
}
