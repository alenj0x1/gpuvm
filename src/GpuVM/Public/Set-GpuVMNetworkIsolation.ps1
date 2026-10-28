function Set-GpuVMNetworkIsolation {
    <#
    .SYNOPSIS
    Isolates the VM's network (default): it keeps internet, but reaches neither the local network nor this PC,
    except for what the stream needs. The rules live on the VM's virtual switch port, outside the guest, so a
    damaged or infected VM cannot remove them. -Enabled $false gives the VM the local network again (for example,
    to reach a NAS). Applied right away, even with the VM running.
    .EXAMPLE
    Set-GpuVMNetworkIsolation -Name win10 -Enabled $true
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Enabled
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    if (-not $state['config']['vm'].Contains('network') -or -not $state['config']['vm']['network']) { $state['config']['vm']['network'] = [ordered]@{} }
    $state['config']['vm']['network']['isolation'] = $Enabled
    Save-GpuVMState $state
    Update-GpuVMNetworkIsolation -Name $Name -State $state
    [ordered]@{ name = $Name; networkIsolation = $Enabled }
}
