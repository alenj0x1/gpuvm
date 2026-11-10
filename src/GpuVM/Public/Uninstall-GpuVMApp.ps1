function Uninstall-GpuVMApp {
    <#
    .SYNOPSIS
    Uninstalls catalog apps from a VM with each app's own uninstaller, silently. Powers it on if needed.
    .EXAMPLE
    Uninstall-GpuVMApp -Name win10 -App discord
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$App
    )
    Assert-Admin
    if (-not $PSCmdlet.ShouldProcess($Name, "Desinstalar $($App -join ', ')")) { return }
    $guest = Start-GuestForApp -Name $Name
    Uninstall-GuestApp -Name $Name -Credential $guest -App $App
}
