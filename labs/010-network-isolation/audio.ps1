# Lab 010: is the missing audio caused by the isolation? Run elevated while Moonlight is streaming:
# pwsh -File labs\010-network-isolation\audio.ps1
# Turns the isolation off for a moment, asks whether the audio came back and always turns it back on.
param(
    [string]$Name = (Get-VM | Where-Object Notes -like "Creada con GpuVM*" | Select-Object -First 1).Name,
    [string]$OutFile = (Join-Path $PSScriptRoot "out\audio-$(Get-Date -Format yyyyMMdd-HHmmss).json")
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$module = Get-Module GpuVM
$state = & $module { param($n) Get-GpuVMState -Name $n } $Name
$guest = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state

$inGuest = {
    $log = 'C:\Program Files\Sunshine\config\sunshine.log'
    [pscustomobject]@{
        audioLog = @(if (Test-Path $log) { Get-Content $log -Tail 400 | Select-String -Pattern 'audio|sink|ping|48000|session|Error|Warning' | Select-Object -Last 40 | ForEach-Object Line })
        devices  = @(Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Status) $($_.FriendlyName)" })
        udp      = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object LocalPort -in 47998, 47999, 48000, 48002, 48010 | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort) pid $($_.OwningProcess)" })
    }
}

$report = [ordered]@{ vm = $Name }
$report['acls'] = @(Get-VMNetworkAdapterExtendedAcl -VMName $Name | Sort-Object Weight -Descending | ForEach-Object { "$($_.Weight) $($_.Direction) $($_.Action) $($_.RemoteIPAddress) $($_.Protocol) local=$($_.LocalPort) remote=$($_.RemotePort) stateful=$($_.Stateful)" })
$report['before'] = Invoke-Command -VMName $Name -Credential $guest -ScriptBlock $inGuest
try {
    Write-Host 'Aislamiento apagado por un momento.' -ForegroundColor Yellow
    Set-GpuVMNetworkIsolation -Name $Name -Enabled $false | Out-Null
    $report['answerWithoutIsolation'] = Read-Host 'Con Moonlight abierto, ¿ahora se oye el audio de la VM? (s/n)'
    $report['after'] = Invoke-Command -VMName $Name -Credential $guest -ScriptBlock $inGuest
}
finally {
    Set-GpuVMNetworkIsolation -Name $Name -Enabled $true | Out-Null
    Write-Host 'Aislamiento encendido de nuevo.' -ForegroundColor Green
    New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
    $report | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 $OutFile
}
