# Lab 057: turns Windows' multiplane overlays (MPO) off or on in a machine (DWM OverlayTestMode = 5, the known fix for
# black flicker with overlays) and restarts DWM so it takes effect. Run elevated.
param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][ValidateSet('off', 'on')][string]$Mpo)
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
$m = Get-Module GpuVM
$state = & $m { param($n) Get-GpuVMState -Name $n } $Name
$cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
Invoke-Command -VMName $Name -Credential $cred -ArgumentList $Mpo {
    param($mpo)
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'
    if ($mpo -eq 'off') { New-ItemProperty $key -Name OverlayTestMode -PropertyType DWord -Value 5 -Force | Out-Null }
    else { Remove-ItemProperty $key -Name OverlayTestMode -ErrorAction SilentlyContinue }
    Stop-Process -Name dwm -Force
    Start-Sleep 5
    "mpo $mpo, dwm $((Get-Process dwm).Id)"
}
