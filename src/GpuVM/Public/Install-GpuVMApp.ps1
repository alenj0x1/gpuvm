function Install-GpuVMApp {
    <#
    .SYNOPSIS
    Installs apps from the catalog (Steam, Epic, Discord...) inside a VM. Powers it on if needed.
    .DESCRIPTION
    Apps already installed are left as they are. -Reinstall uninstalls them first and installs them again.
    .EXAMPLE
    Install-GpuVMApp -Name win10 -App steam, discord
    .EXAMPLE
    Install-GpuVMApp -Name win10 -App discord -Reinstall
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$App,
        [switch]$Reinstall
    )
    Assert-Admin
    $guest = Start-GuestForApp -Name $Name
    if ($Reinstall) {
        # An app whose uninstall failed is not installed over: it would only report it as already there.
        $removed = @(Uninstall-GuestApp -Name $Name -Credential $guest -App $App)
        $App = @($removed | Where-Object { $_['status'] -in 'uninstalled', 'absent' } | ForEach-Object { $_['app'] })
        foreach ($failed in @($removed | Where-Object { $_['status'] -notin 'uninstalled', 'absent' })) { $failed }
        if (-not $App) { return }
    }
    Install-GuestApp -Name $Name -Credential $guest -App $App
}
