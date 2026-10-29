function Set-GpuVMCleanup {
    <#
    .SYNOPSIS
    Sets how clean Windows is inside a VM: none, privacy (telemetry to the minimum, no ads, suggestions, Bing in
    Start, Copilot or Recall), apps (also removes preinstalled apps, OneDrive and widgets) or minimal (also turns
    off telemetry and unneeded services). Each level includes the ones before it. A lower level undoes the
    settings of the higher ones; removed apps come back from Microsoft Store. Powers the VM on if needed.
    Never touches Microsoft Defender, Windows Update, SmartScreen, UAC or the firewall.
    .EXAMPLE
    Set-GpuVMCleanup -Name win10 -Level privacy
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('none', 'privacy', 'apps', 'minimal')][string]$Level
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    $guest = Get-GpuVMGuestCredential -State $state
    if (-not $guest) { throw 'Guarda la contraseña de Windows de la VM para que GpuVM pueda limpiar Windows.' }
    $vm = Get-VM -Name $Name
    if ($vm.State -eq 'Off') {
        Assert-VMCanStart -Name $Name
        Write-Step 'Encendiendo'
        Start-VM -Name $Name
    }
    Wait-GuestReady -Name $Name -Credential $guest
    Write-Step 'Limpiando Windows'
    $code = Get-Content -Raw -Encoding UTF8 -LiteralPath (Get-RepoPath 'guest\cleanup.ps1')
    $results = Invoke-Command -VMName $Name -Credential $guest -ErrorAction Stop -ArgumentList $code, $Level -ScriptBlock {
        param($code, $level)
        . ([scriptblock]::Create($code))
        # Only primitive values go back to the host.
        Invoke-GpuVMCleanup -Level $level | ForEach-Object { @{ name = [string]$_.name; ok = [bool]$_.ok; detail = [string]$_.detail } }
    }
    $failed = @($results | Where-Object { -not $_['ok'] })
    foreach ($item in $failed) { Write-Warning "No se pudo aplicar $($item['name']): $($item['detail'])" }

    $state = Get-GpuVMState -Name $Name
    $state['config']['guest']['cleanup'] = $Level
    Save-GpuVMState $state
    Write-Step $(if ($failed) { 'Limpieza aplicada con avisos' } else { 'Limpieza aplicada' })
    [ordered]@{ name = $Name; cleanup = $Level; failed = @($failed | ForEach-Object { $_['name'] }) }
}
