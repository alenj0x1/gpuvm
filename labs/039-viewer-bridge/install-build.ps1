# Lab 039 helper: installs the latest build without the installer's pages (NSIS /S) and opens GpuVM again, so an
# iteration needs only the person's Yes in the UAC prompt. That prompt stays on purpose: the service only trusts the
# gpuvm.exe in Program Files (admins only), and anything that installed there without it would let any program do
# the same. The app is ended without its quit handler, so the machines keep running.
param([string]$Setup = (Join-Path $PSScriptRoot '..\..\app\src-tauri\target\release\bundle\nsis\GpuVM_0.8.0_x64-setup.exe'))
$Setup = (Resolve-Path $Setup).Path
Get-Process gpuvm, GpuVMViewer -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800
$before = (Get-Item 'C:\Program Files\GpuVM\gpuvm.exe').LastWriteTime
try { $p = Start-Process -FilePath $Setup -ArgumentList '/S' -Verb RunAs -PassThru -ErrorAction Stop }
catch { 'UAC was declined or timed out: nothing installed'; & (Join-Path $PSScriptRoot 'run-build.ps1') -Installed; return }
$p.WaitForExit()
$after = (Get-Item 'C:\Program Files\GpuVM\gpuvm.exe').LastWriteTime
"installer exit $($p.ExitCode); gpuvm.exe $before -> $after"
& (Join-Path $PSScriptRoot 'run-build.ps1') -Installed
