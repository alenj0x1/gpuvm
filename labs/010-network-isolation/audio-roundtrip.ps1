# Audio end to end, with Moonlight open: plays a Windows sound inside the VM (in the signed-in user's session) and
# measures the peak at the same time on every output of the VM and of this PC. Changes nothing permanently.
# pwsh -File labs\010-network-isolation\audio-roundtrip.ps1
param(
    [string]$Name = (Get-VM | Where-Object Notes -like "Creada con GpuVM*" | Select-Object -First 1).Name,
    [int]$Seconds = 8
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$module = Get-Module GpuVM
$state = & $module { param($n) Get-GpuVMState -Name $n } $Name
$guest = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state
$meter = Get-Content -Raw (Join-Path $PSScriptRoot 'audio-meter.ps1')

# The PC's meter runs as the signed-in user's PowerShell, in parallel with the VM's.
$hostMeter = Start-ThreadJob -ArgumentList $meter, $Seconds -ScriptBlock {
    param($code, $s) & ([scriptblock]::Create($code)) -Seconds $s | Out-String -Width 200
}

$inGuest = Invoke-Command -VMName $Name -Credential $guest -ArgumentList $meter, $Seconds -ScriptBlock {
    param($code, $s)
    # The sound has to play in the user's session (console), where Sunshine captures; a task runs it there.
    $player = "`$p=[Media.SoundPlayer]::new('C:\Windows\Media\Alarm01.wav');`$p.PlayLooping();Start-Sleep $($s + 2);`$p.Stop()"
    $user = (Get-CimInstance Win32_ComputerSystem).UserName
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -Command $player"
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
    Register-ScheduledTask -TaskName 'GpuVM-Lab010-Audio' -Action $action -Principal $principal -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName 'GpuVM-Lab010-Audio'
        Start-Sleep -Milliseconds 800
        $levels = & ([scriptblock]::Create($code)) -Seconds $s | Out-String -Width 200
        [pscustomobject]@{ user = $user; levels = $levels }
    }
    finally { Unregister-ScheduledTask -TaskName 'GpuVM-Lab010-Audio' -Confirm:$false }
}
$pc = $hostMeter | Wait-Job | Receive-Job
Remove-Job $hostMeter

Write-Host "`n== Dentro de la VM ($($inGuest.user)), sonando Alarm01.wav" -ForegroundColor Cyan
$inGuest.levels
Write-Host "== En este PC (lo que reproduce Moonlight)" -ForegroundColor Cyan
$pc
