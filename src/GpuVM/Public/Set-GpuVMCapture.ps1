function Set-GpuVMCapture {
    <#
    .SYNOPSIS
    Chooses how Sunshine captures the VM's screen. "ddx" (default) shows everything, including Windows'
    administrator prompts. "wgc" also shows programs in exclusive fullscreen, which "ddx" sees as a black screen
    on a virtual display, but not the administrator prompts. Applied now if the VM is running, otherwise on open.
    .EXAMPLE
    Set-GpuVMCapture -Name win10 -Mode wgc
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('ddx', 'wgc')][string]$Mode
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    if (-not $state['streaming']) { throw "La VM '$Name' se creó sin streaming." }
    $state['config']['streaming']['captureMode'] = $Mode
    Save-GpuVMState $state

    $guest = Get-GpuVMGuestCredential -State $state
    if ((Get-VM -Name $Name).State -eq 'Running' -and $guest) {
        $null = Set-GuestCaptureMode -Name $Name -Credential $guest -Mode $Mode
    }
    [ordered]@{ name = $Name; captureMode = $Mode }
}
