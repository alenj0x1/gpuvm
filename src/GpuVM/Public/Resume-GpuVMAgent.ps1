function Resume-GpuVMAgent {
    <#
    .SYNOPSIS
    Gives control of the machine back to the agent session (after Suspend-GpuVMAgent or Request-GpuVMHuman).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name
    )
    Invoke-AgentBroker -Command 'Resume-GpuVMAgent' -Arguments (ConvertTo-AgentArguments $PSBoundParameters)
}
