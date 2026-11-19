# Lab 054 runner on the shared PC: waits for its turn in C:\GpuVM\.lab-queue, takes C:\GpuVM\.lab-lock (exclusive
# create, with this process's PID so others can tell a dead holder), runs take-control.mjs and always releases the lock.
#   pwsh -NoProfile -File labs/054-agent-ui/run.ps1 [-Machine template:agent-tpl] [-MemoryGB 4] [-MaxMinutes 40]
#
# Lesson (2026-11-19): waiting on `node ... 2>&1` waited on node's output PIPE, which a process node started inherited
# (open_viewer runs gpuvm.exe --view, which may become the long-lived app): node ended, the pipe never did, the finally
# never ran, and the lock stayed held for 2 hours. Here node writes to a file and we wait on its PROCESS, with a limit.
#   -Script notify.mjs: the request_human notification instead of take-control.
param([string]$Machine = 'template:agent-tpl', [int]$MemoryGB = 4, [int]$MaxMinutes = 40, [int]$WaitTurnMinutes = 360,
    [string]$Script = 'take-control.mjs')
$me = 'agent-ui'; $lock = 'C:\GpuVM\.lab-lock'; $queue = 'C:\GpuVM\.lab-queue'
$here = $PSScriptRoot
$out = Join-Path $here 'out'; New-Item -ItemType Directory -Force $out | Out-Null
$log = Join-Path $out ("run-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

# Wait for the turn: lock free and this session first in the queue (or the queue empty).
$until = (Get-Date).AddMinutes($WaitTurnMinutes); $taken = $false
while (-not $taken -and (Get-Date) -lt $until) {
    if (-not (Test-Path $lock)) {
        $lines = @(if (Test-Path $queue) { Get-Content $queue | Where-Object { $_.Trim() } })
        if (-not $lines.Count -or $lines[0].Trim() -eq $me -or $lines[0].StartsWith("$me |")) {
            try {
                $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
                $bytes = [Text.Encoding]::UTF8.GetBytes("$me | lab 054: $Script on own disposable lab054-* | pid $PID | $(Get-Date -Format o)")
                $fs.Write($bytes, 0, $bytes.Length); $fs.Close(); $taken = $true
                $rest = @($lines | Where-Object { $_.Trim() -ne $me -and -not $_.StartsWith("$me |") })
                Set-Content $queue ($(if ($rest.Count) { $rest } else { '' }))
            } catch { }
        }
    }
    if (-not $taken) { Start-Sleep -Seconds 20 }
}
if (-not $taken) { "timed out waiting for the turn"; exit 1 }
"taken $(Get-Date -Format o) (pid $PID); log $log"
try {
    $env:LAB054_MEMORY_GB = "$MemoryGB"
    $node = Start-Process node -ArgumentList "`"$(Join-Path $here $Script)`"", $Machine, 10 -NoNewWindow -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    if (-not $node.WaitForExit($MaxMinutes * 60000)) {
        "lab over $MaxMinutes min: stopped"
        Stop-Process -Id $node.Id -Force -ErrorAction SilentlyContinue
    }
    Get-Content $log, "$log.err" -ErrorAction SilentlyContinue
} finally {
    # Only our own lock (another session may have removed a stale one and taken its turn).
    $l = Get-Content $lock -Raw -ErrorAction SilentlyContinue
    if ($l -like "$me |*pid $PID |*") { Remove-Item $lock; "lock released $(Get-Date -Format o)" }
}
