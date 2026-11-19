function Resolve-GpuVMAgentOffer {
    <#
    .SYNOPSIS
    Approves or declines an offered file. Approved files are copied as you into Downloads\GpuVM\<machine>, marked as downloaded from the internet, never overwriting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('approve', 'decline')][string]$Answer
    )
    Invoke-AgentBroker -Command 'Resolve-GpuVMAgentOffer' -Arguments (ConvertTo-AgentArguments $PSBoundParameters)
}
