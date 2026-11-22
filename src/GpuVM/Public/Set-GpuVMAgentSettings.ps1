function Set-GpuVMAgentSettings {
    <#
    .SYNOPSIS
    Changes the limits of new agent sessions (0 = no limit, the default) and how long requests and offers wait for the person.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(0, 100000)][int]$MaxSteps,
        [ValidateRange(0, 1440)][int]$MaxMinutes,
        [ValidateRange(10, 86400)][int]$ApprovalTimeoutSec
    )
    Invoke-AgentBroker -Command 'Set-GpuVMAgentSettings' -Arguments (ConvertTo-AgentArguments $PSBoundParameters)
}
