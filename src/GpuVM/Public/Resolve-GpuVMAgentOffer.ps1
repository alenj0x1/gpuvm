function Resolve-GpuVMAgentOffer {
    <#
    .SYNOPSIS
    Accepts or refuses an offered file. Accepted files are copied as you into Downloads\GpuVM\<machine>, marked as downloaded from the internet, never overwriting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][bool]$Accept
    )
    Invoke-AgentBroker -Command 'Resolve-GpuVMAgentOffer' -Arguments (ConvertTo-AgentArguments $PSBoundParameters)
}
