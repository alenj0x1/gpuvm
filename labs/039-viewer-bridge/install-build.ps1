# Lab 039 helper: installs the latest build without the installer's pages (NSIS /S) and opens GpuVM again, so an
# iteration needs only the person's Yes in the UAC prompt. That prompt stays on purpose: the service only trusts the
# gpuvm.exe in Program Files (admins only), and anything that installed there without it would let any program do
# the same. The app is ended without its quit handler, so the machines keep running.
param([string]$Setup = (Join-Path $PSScriptRoot '..\..\app\src-tauri\target\release\bundle\nsis\GpuVM_0.8.0_x64-setup.exe'))
$Setup = (Resolve-Path $Setup).Path
Get-Process gpuvm, GpuVMViewer -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800
$before = (Get-Item 'C:\Program Files\GpuVM\gpuvm.exe').LastWriteTime
$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($elevated) {
    $p = Start-Process -FilePath $Setup -ArgumentList '/S' -PassThru; $p.WaitForExit()
} else {
    # A sandboxed shell can't raise a UAC prompt: a one-shot task of this user asks for it on the real desktop.
    $done = Join-Path $env:TEMP ('gpuvm-install-' + [guid]::NewGuid().ToString('N') + '.txt')
    $cmd = "try { `$p = Start-Process -FilePath '$Setup' -ArgumentList '/S' -Verb RunAs -PassThru -ErrorAction Stop; `$p.WaitForExit(); `$p.ExitCode } catch { 'declined' } | Set-Content '$done'"
    $name = 'GpuVM-lab-install-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $pwsh = (Get-Command pwsh).Source
    Register-ScheduledTask -TaskName $name -Action (New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -WindowStyle Hidden -Command $cmd") -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries) | Out-Null
    Start-ScheduledTask -TaskName $name
    $deadline = (Get-Date).AddMinutes(4)
    while (-not (Test-Path $done) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
    $result = if (Test-Path $done) { (Get-Content $done) -join ''; Remove-Item $done } else { 'no answer' }
    if ($result -ne '0') { "installer: $result (nothing installed)"; & (Join-Path $PSScriptRoot 'run-build.ps1') -Installed; return }
    $p = [pscustomobject]@{ ExitCode = 0 }
}
$after = (Get-Item 'C:\Program Files\GpuVM\gpuvm.exe').LastWriteTime
"installer exit $($p.ExitCode); gpuvm.exe $before -> $after"
& (Join-Path $PSScriptRoot 'run-build.ps1') -Installed
