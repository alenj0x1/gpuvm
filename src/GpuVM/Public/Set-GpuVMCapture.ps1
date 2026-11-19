function Set-GpuVMCapture {
    <#
    .SYNOPSIS
    Chooses how Sunshine captures the VM's screen. "wgc" (default) shows the picture right after connecting and
    programs in exclusive fullscreen; Windows administrator prompts can't be streamed, so GpuVM shows them in its
    own card (Get-GpuVMAdminPrompt, Resolve-GpuVMAdminPrompt). "ddx" streams the prompts too, but the picture can
    stay black after connecting until something on screen changes, and exclusive fullscreen programs show black.
    Applied now if the VM is running, otherwise on open.
    .EXAMPLE
    Set-GpuVMCapture -Name win10 -Mode ddx
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('ddx', 'wgc')][string]$Mode
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    if (-not $state['streaming']) { throw "The VM '$Name' was created without streaming." }
    if ($Mode -eq 'wgc' -and [string]$state['use'] -eq 'agent') {
        throw "'$Name' is an agent machine: Sunshine runs as a service there (ddx), never as the account the agent uses."
    }
    $state['config']['streaming']['captureMode'] = $Mode
    Save-GpuVMState $state

    $guest = Get-GpuVMGuestCredential -State $state
    if ((Get-VM -Name $Name).State -eq 'Running' -and $guest) {
        $null = Set-GuestCaptureMode -Name $Name -Credential $guest -Mode $Mode
    }
    [ordered]@{ name = $Name; captureMode = $Mode }
}
