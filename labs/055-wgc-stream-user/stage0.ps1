# Lab 055, inside the guest, stage 0: a SYSTEM scheduled task (session 0). Starts stage1.ps1 as SYSTEM in the console
# session, where it can reach that session's window station.
$dir = 'C:\GpuVMLab055'
$log = Join-Path $dir 'launch.log'
try {
    Add-Type -Path (Join-Path $dir 'StreamLauncher.cs')
    $session = [StreamLauncher]::ConsoleSession()
    $id = [StreamLauncher]::RunAsSystemInSession($session, "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$dir\stage1.ps1`"")
    Add-Content $log "$(Get-Date -Format HH:mm:ss.fff) stage0: console session $session, stage1 pid $id"
}
catch { Add-Content $log "$(Get-Date -Format HH:mm:ss.fff) stage0: ERROR $($_.Exception.Message)" }
