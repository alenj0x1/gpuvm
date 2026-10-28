# Candidate: Sunshine captures Steam Streaming Speakers (installed by Sunshine) instead of VB-CABLE, whose loopback
# returns silence. Points virtual_sink at it, reopens Moonlight, plays a sound in the VM and measures on this PC.
# Keeps the change only if the sound arrives; otherwise puts VB-CABLE back.
# pwsh -File labs\010-network-isolation\audio-steam.ps1
param(
    [string]$Name = (Get-VM | Where-Object Notes -like "Creada con GpuVM*" | Select-Object -First 1).Name,
    [int]$Seconds = 8
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$module = Get-Module GpuVM
$state = & $module { param($n) Get-GpuVMState -Name $n } $Name
$guest = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state
$sunshine = & $module { param($s) Get-SunshineCredential -State $s } $state
$endpoint = & $module { param($n) Get-GpuVMEndpoint -Name $n -TimeoutSec 60 } $Name
$meter = Get-Content -Raw (Join-Path $PSScriptRoot 'audio-meter.ps1')

$steam = Invoke-Command -VMName $Name -Credential $guest -ScriptBlock {
    Get-PnpDevice -Class AudioEndpoint -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'SWD\MMDEVAPI\{0.0.0.*' -and $_.FriendlyName -like '*Steam Streaming Speakers*' -and $_.Status -eq 'OK' } |
        Select-Object -First 1 -ExpandProperty FriendlyName
}
if (-not $steam) { throw 'La VM no tiene Steam Streaming Speakers activo.' }
$previous = 'Altavoces (VB-Audio Virtual Cable)'
# Written in sunshine.conf and applied by restarting the service: Sunshine's /api/restart left it stopped.
$setSink = {
    param($sink)
    Invoke-Command -VMName $Name -Credential $guest -ArgumentList $sink -ScriptBlock {
        param($sink)
        $conf = 'C:\Program Files\Sunshine\config\sunshine.conf'
        $lines = @(Get-Content $conf | Where-Object { $_ -notmatch '^\s*virtual_sink\s*=' }) + "virtual_sink = $sink"
        [IO.File]::WriteAllLines($conf, [string[]]$lines, [Text.UTF8Encoding]::new($false))
        Get-Service | Where-Object Name -like '*sunshine*' | Restart-Service -Force
    }
    & $module { param($a, $c) Wait-SunshineReady -Address $a -Credential $c -TimeoutSec 120 } $endpoint.Address $sunshine
}
Write-Host "virtual_sink -> '$steam'" -ForegroundColor Cyan
& $setSink $steam

# A new session is what makes Sunshine pick the sink again.
Get-Process moonlight -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3
$client = $state['config']['streaming']['client']
$moonlight = & $module { Get-MoonlightPath }
$arguments = & $module { param($a, $c) Get-MoonlightStreamArguments -Address $a -Client $c } $endpoint.Address $client
& $module { param($f, $a) Start-UnelevatedProcess -FilePath $f -ArgumentList $a } $moonlight $arguments | Out-Null
Write-Host 'Moonlight abierto; en 15 s suena una alarma en la VM.' -ForegroundColor Cyan
Start-Sleep -Seconds 15

$hostMeter = Start-ThreadJob -ArgumentList $meter, $Seconds -ScriptBlock { param($code, $s) & ([scriptblock]::Create($code)) -Seconds $s | Out-String -Width 200 }
Invoke-Command -VMName $Name -Credential $guest -ArgumentList $Seconds -ScriptBlock {
    param($s)
    $user = (Get-CimInstance Win32_ComputerSystem).UserName
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -Command `$p=[Media.SoundPlayer]::new('C:\Windows\Media\Alarm01.wav');`$p.PlayLooping();Start-Sleep $($s + 2)"
    Register-ScheduledTask -TaskName 'GpuVM-Lab010-Play' -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive) -Force | Out-Null
    Start-ScheduledTask -TaskName 'GpuVM-Lab010-Play'
    Start-Sleep -Seconds ($s + 2)
    Unregister-ScheduledTask -TaskName 'GpuVM-Lab010-Play' -Confirm:$false
}
$pc = $hostMeter | Wait-Job | Receive-Job
Remove-Job $hostMeter
Write-Host "`n== En este PC (lo que reproduce Moonlight)" -ForegroundColor Cyan
$pc
$answer = Read-Host '¿Se oyó la alarma? (s/n)'
if ($answer -ne 's') {
    & $setSink $previous
    Write-Host "Se dejó virtual_sink como estaba: '$previous'" -ForegroundColor Yellow
}
else { Write-Host "Queda Steam Streaming Speakers. Ojo: «Abrir» lo vuelve a cambiar a VB-CABLE hasta que GpuVM se actualice." -ForegroundColor Green }
