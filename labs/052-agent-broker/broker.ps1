# Runs the agent broker of this branch's gpuvm-host (debug build, `gpuvm-host broker`) as SYSTEM, next to the
# installed GpuVM service (which doesn't have the broker yet), or stops it. The exe is copied first into
# C:\GpuVM\lab052 (administrators only): never run as SYSTEM from a folder the user can write. Run elevated.
param([switch]$Stop, [switch]$Build)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$dir = 'C:\GpuVM\lab052'
$task = 'GpuVMLab052-broker'

function Stop-Broker {
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
    }
    Get-CimInstance Win32_Process -Filter "Name = 'gpuvm-host.exe'" |
        Where-Object { $_.ExecutablePath -like "$dir\*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}

Stop-Broker
if ($Stop) { 'broker stopped'; return }
if ($Build) {
    & cargo build --manifest-path (Join-Path $root 'app\host\Cargo.toml') 2>&1 | Select-Object -Last 2
    if ($LASTEXITCODE) { throw 'build failed' }
}
New-Item -ItemType Directory -Force $dir | Out-Null
Copy-Item (Join-Path $root 'app\host\target\debug\gpuvm-host.exe') $dir -Force
$action = New-ScheduledTaskAction -Execute (Join-Path $dir 'gpuvm-host.exe') -Argument 'broker'
$principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $task
# Ready when the module's pipe answers.
Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 15) {
    try { $b = Get-GpuVMAgentBroker; "broker up in {0:N0} ms: {1}" -f $sw.Elapsed.TotalMilliseconds, ($b | ConvertTo-Json -Compress); return }
    catch { Start-Sleep -Milliseconds 200 }
}
throw 'the broker did not answer in 15 s'
