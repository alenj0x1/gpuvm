function Get-GpuVMAgentBroker {
    <#
    .SYNOPSIS
    Whether the GpuVM service is listening for agents (and why not), and how many are connected.
    #>
    [CmdletBinding()]
    param()
    Invoke-AgentBroker -Command 'Get-GpuVMAgentBroker' -Arguments (ConvertTo-AgentArguments $PSBoundParameters)
}
