function Install-GpuVMApp {
    <#
    .SYNOPSIS
    Installs apps from the catalog (Steam, Epic, Discord...) inside a VM. Powers it on if needed.
    .EXAMPLE
    Install-GpuVMApp -Name win10 -App steam, discord
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$App
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    $guest = Get-GpuVMGuestCredential -State $state
    if (-not $guest) { throw 'Guarda la contraseña de Windows de la VM para que GpuVM pueda instalar apps.' }
    $vm = Get-VM -Name $Name
    if ($vm.State -eq 'Off') {
        Assert-VMCanStart -Name $Name
        Write-Step 'Encendiendo'
        Start-VM -Name $Name
    }
    Wait-GuestReady -Name $Name -Credential $guest
    Install-GuestApp -Name $Name -Credential $guest -App $App
}
