function Get-GpuVMAgentRequest {
    <#
    .SYNOPSIS
    What agent sessions ask the person to allow (administrator steps, network, going back to a restore point, deleting a machine) and its state.
    #>
    [CmdletBinding()]
    param(
        [string]$Id
    )
    Invoke-AgentBroker -Command 'Get-GpuVMAgentRequest' -Arguments (ConvertTo-AgentArguments $PSBoundParameters)
}
