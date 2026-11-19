function Get-GpuVMAgent {
    <#
    .SYNOPSIS
    Machines with GpuVM's agent and their state: ready (connected), starting, off or no-agent; who took them; paused or not.
    #>
    [CmdletBinding()]
    param(
        [string]$Name
    )
    Invoke-AgentBroker -Command 'Get-GpuVMAgent' -Arguments (ConvertTo-AgentArguments $PSBoundParameters)
}
