function Get-GpuVMAgentSettings {
    <#
    .SYNOPSIS
    Limits of agent sessions (steps, minutes), how long requests wait for the person, and which clients may approve low-risk steps themselves.
    #>
    [CmdletBinding()]
    param()
    Invoke-AgentBroker -Command 'Get-GpuVMAgentSettings' -Arguments (ConvertTo-AgentArguments $PSBoundParameters)
}
