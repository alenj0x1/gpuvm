# Waits (polling every 30 s, at most -MaxMinutes) for this session's turn and takes the shared lab lock
# C:\GpuVM\.lab-lock exclusively (CreateNew: fails if another session took it first) with this session's name and
# task. The turn: this session is first in C:\GpuVM\.lab-queue (it is added at the end if missing, and its line is
# removed once the lock is taken), or there is no queue. Exit 0 when held.
param([Parameter(Mandatory)][string]$What, [int]$MaxMinutes = 120, [string]$Me = 'admin-dock')
$file = 'C:\GpuVM\.lab-lock'
$queue = 'C:\GpuVM\.lab-queue'
function Get-Queue { if (Test-Path $queue) { @(Get-Content $queue | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() } }
if ((Test-Path $queue) -and (Get-Queue) -notcontains $Me) { Add-Content $queue $Me }
$end = (Get-Date).AddMinutes($MaxMinutes)
while ((Get-Date) -lt $end) {
    $line = Get-Queue
    if (-not $line.Count -or $line[0] -eq $Me) {
        try {
            $fs = [IO.File]::Open($file, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $bytes = [Text.Encoding]::UTF8.GetBytes("$Me | $What | $((Get-Date).ToString('o'))")
            $fs.Write($bytes, 0, $bytes.Length); $fs.Close()
            if (Test-Path $queue) { Set-Content $queue @(Get-Queue | Where-Object { $_ -ne $Me }) }
            "lock taken at $(Get-Date -Format HH:mm:ss)"
            exit 0
        }
        catch [IO.IOException] { }
    }
    Start-Sleep -Seconds 30
}
"gave up after $MaxMinutes min: $(Get-Content $file -ErrorAction SilentlyContinue)"
exit 1
