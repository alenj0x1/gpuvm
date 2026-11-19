function Suspend-GpuVMAgent {
    <#
    .SYNOPSIS
    The person takes control of the machine: the agent's requests are stopped and refused (paused) until Resume-GpuVMAgent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Message
    )
    Invoke-AgentBroker -Command 'Suspend-GpuVMAgent' -Arguments (ConvertTo-AgentArguments $PSBoundParameters)
}
