# Shared lab lock (C:\GpuVM\.lab-lock) for the sessions sharing this PC: GPU/VM work and heavy disk I/O.
# . .\lock.ps1; Enter-LabLock 'disks-backup | lab 045: ...'; try { ... } finally { Exit-LabLock }
# Queue (C:\GpuVM\.lab-queue, one session name per line): the lock is taken only when the queue is empty or this
# session is its first line, and that line is removed when it is taken.
# A runner that already holds the lock for several labs sets $env:LAB045_LOCK_HELD = '1' and the inner labs don't
# take or release it.
$script:LabLockPath = 'C:\GpuVM\.lab-lock'
$script:LabQueuePath = 'C:\GpuVM\.lab-queue'
$script:LabSession = 'disks-backup'
$script:LabLockOwned = $false

function Get-LabQueue { @(if (Test-Path $script:LabQueuePath) { Get-Content $script:LabQueuePath | ForEach-Object { $_.Trim() } | Where-Object { $_ } }) }

function Enter-LabLock {
    param([Parameter(Mandatory)][string]$What, [int]$TimeoutMinutes = 120)
    if ($env:LAB045_LOCK_HELD -eq '1') { return }
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        $queue = Get-LabQueue
        $myTurn = -not $queue.Count -or $queue[0] -like "$script:LabSession*"
        if ($myTurn) {
            try {
                $fs = [IO.File]::Open($script:LabLockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $bytes = [Text.Encoding]::UTF8.GetBytes("$What | $((Get-Date).ToString('o'))")
                $fs.Write($bytes, 0, $bytes.Length); $fs.Dispose()
                $script:LabLockOwned = $true
                if ($queue.Count -and $queue[0] -like "$script:LabSession*") {
                    Set-Content -LiteralPath $script:LabQueuePath -Value @($queue | Select-Object -Skip 1)
                }
                return
            }
            catch [IO.IOException] { }
        }
        if ((Get-Date) -gt $deadline) { throw "Lab lock not free after $TimeoutMinutes min: $(Get-Content $script:LabLockPath -Raw -ErrorAction SilentlyContinue) / queue: $($queue -join ', ')" }
        Write-Host "waiting: lock=$(Get-Content $script:LabLockPath -Raw -ErrorAction SilentlyContinue) queue=$($queue -join ', ')"
        Start-Sleep 30
    }
}

# Says in the lock what is happening now (other sessions read it), e.g. that win-gpu is off.
function Set-LabLockNote {
    param([Parameter(Mandatory)][string]$Note)
    if (Test-Path $script:LabLockPath) {
        $first = (Get-Content $script:LabLockPath -TotalCount 1)
        Set-Content -LiteralPath $script:LabLockPath -Value @($first, "$((Get-Date).ToString('HH:mm')) $Note")
    }
}

function Exit-LabLock {
    if ($env:LAB045_LOCK_HELD -eq '1') { return }
    if ($script:LabLockOwned -and (Test-Path $script:LabLockPath)) { Remove-Item $script:LabLockPath -Force }
    $script:LabLockOwned = $false
}

# Waits until C: writes stay under -MaxMBps for 10 s (other sessions' copies distort I/O timings).
function Wait-DiskQuiet {
    param([int]$MaxMBps = 50, [int]$TimeoutSeconds = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $s = (Get-Counter '\PhysicalDisk(_Total)\Disk Bytes/sec' -SampleInterval 1 -MaxSamples 10).CounterSamples.CookedValue
        $mbps = ($s | Measure-Object -Average).Average / 1MB
        if ($mbps -lt $MaxMBps) { return [math]::Round($mbps, 1) }
        Write-Host "disk busy: $([math]::Round($mbps)) MB/s"
    }
    throw "C: did not get quiet (< $MaxMBps MB/s) in $TimeoutSeconds s."
}
