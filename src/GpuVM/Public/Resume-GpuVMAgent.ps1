function Resume-GpuVMAgent {
    <#
    .SYNOPSIS
    Gives the machine back to its agent session (after Suspend-GpuVMAgent or Request-GpuVMHuman).
    #>
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$Connection
    )
    Invoke-AgentBroker -Command 'Resume-GpuVMAgent' -Arguments (ConvertTo-AgentArguments $PSBoundParameters)
}
