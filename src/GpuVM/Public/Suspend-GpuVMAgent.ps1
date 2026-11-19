function Suspend-GpuVMAgent {
    <#
    .SYNOPSIS
    The person pauses an agent (Reason person) or takes control of its machine (Reason control): its requests stop and are refused until Resume-GpuVMAgent.
    #>
    [CmdletBinding()]
    param(
        [string]$Name,
        # An agent session's id, or '*' for every session.
        [string]$Connection,
        [ValidateSet('person', 'control')][string]$Reason = 'person',
        [string]$Message
    )
    Invoke-AgentBroker -Command 'Suspend-GpuVMAgent' -Arguments (ConvertTo-AgentArguments $PSBoundParameters)
}
