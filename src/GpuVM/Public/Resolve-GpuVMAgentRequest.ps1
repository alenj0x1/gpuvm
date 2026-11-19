function Resolve-GpuVMAgentRequest {
    <#
    .SYNOPSIS
    Allows or denies what an agent session asked for; -ForTask allows it for the rest of that session.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][bool]$Allow,
        [switch]$ForTask
    )
    Invoke-AgentBroker -Command 'Resolve-GpuVMAgentRequest' -Arguments (ConvertTo-AgentArguments $PSBoundParameters)
}
