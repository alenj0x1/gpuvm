# Lab 055: the installed GpuVM end to end on a fresh copy of agent-tpl. New copy with the installed module, then
# `gpuvm.exe --view <copy>` while the app runs: the app installs the pending agent (with GpuVM's Sunshine fork),
# runs Connect-GpuVM -Viewer and opens its viewer. Saves the viewer's window (PrintWindow) every 10 s until it shows
# the desktop or -WatchSec passes, then reads the guest's capture state. Run elevated.
param([string]$Template = 'agent-tpl', [string]$Name = 'agent058', [int]$WatchSec = 600)
$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot 'out'
$installed = Join-Path $env:ProgramFiles 'GpuVM'
$app = Join-Path $installed 'gpuvm.exe'
function Line($what) { Write-Host "$(Get-Date -Format HH:mm:ss) $what" }
if (-not (Get-Process gpuvm -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $app })) { throw 'GpuVM (the app) is not running.' }
Import-Module (Join-Path $installed 'gpuvm\src\GpuVM\GpuVM.psd1') -Force
$m = Get-Module GpuVM
if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false }
New-GpuVM -Name $Name -Template $Template | Out-Null
Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes 4GB
Start-VM -Name $Name
$t0 = Get-Date
Line "copy started; gpuvm.exe --view $Name"
Start-Process -FilePath $app -ArgumentList '--view', $Name
$shot = Join-Path $PSScriptRoot 'shot.ps1'
$result = 'no picture'
while (((Get-Date) - $t0).TotalSeconds -lt $WatchSec) {
    Start-Sleep -Seconds 10
    $v = Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
    if (-not $v) { continue }
    $sec = [int]((Get-Date) - $t0).TotalSeconds
    $file = Join-Path $out "app-$Name-$sec`s.png"
    $lit = powershell.exe -NoProfile -File $shot -Hwnd ([long]$v.MainWindowHandle) -Path $file
    Line "viewer window at $sec s: $lit"
    if ("$lit" -match 'range (\d+)-(\d+)' -and ([int]$Matches[2] - [int]$Matches[1]) -gt 150 -and "$lit" -match 'lit (9\d|100)') { $result = "picture at $sec s ($file)"; break }
}
Line $result
$state = & $m { param($n) Get-GpuVMState -Name $n } $Name
$cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
Invoke-Command -VMName $Name -Credential $cred {
    $d = 'C:\Program Files\Sunshine'
    "capture: $((Select-String "$d\config\sunshine.conf" -Pattern '^\s*capture').Line); helper: $(Test-Path "$d\tools\sunshine_wgc_capture.exe")"
    Get-CimInstance Win32_Process -Filter "Name='sunshine.exe' OR Name='sunshine_wgc_capture.exe'" | ForEach-Object { $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner; "$($_.Name) s$($_.SessionId) $($o.Domain)\$($o.User)" }
}
