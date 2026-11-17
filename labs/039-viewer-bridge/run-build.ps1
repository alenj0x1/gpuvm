# Lab 039 helper: runs the freshly built app (target\release, laid out like the installed one: gpuvm\, pwsh\, viewer)
# in place of the installed GpuVM, so each iteration is tested without installing. Same user, unelevated: the
# installed service keeps doing the privileged work. The machines keep running: the app is ended without its quit
# handler (which may stop them). Its viewer goes with it.
#   run-build.ps1            (the release build)
#   run-build.ps1 -Installed (back to the installed app)
param([switch]$Installed)
$exe = if ($Installed) { 'C:\Program Files\GpuVM\gpuvm.exe' } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..\app\src-tauri\target\release\gpuvm.exe')).Path }
Get-Process gpuvm, GpuVMViewer -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800
# Started by the Task Scheduler, outside the sandbox this shell may run in (the app needs the real desktop session).
$name = 'GpuVM-lab-run-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$action = New-ScheduledTaskAction -Execute $exe
Register-ScheduledTask -TaskName $name -Action $action -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries) | Out-Null
Start-ScheduledTask -TaskName $name
Start-Sleep -Seconds 2
Unregister-ScheduledTask -TaskName $name -Confirm:$false
$p = Get-Process gpuvm -ErrorAction SilentlyContinue | Select-Object -First 1
if ($p) { "running $($p.Path) (pid $($p.Id))" } else { 'not running' }
