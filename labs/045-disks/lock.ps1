# Shared lab lock (C:\GpuVM\.lab-lock) for the sessions sharing this PC: GPU/VM work and heavy disk I/O.
# . .\lock.ps1; Enter-LabLock 'disks-backup | lab 045: ...'; try { ... } finally { Exit-LabLock }
$script:LabLockPath = 'C:\GpuVM\.lab-lock'
$script:LabLockOwned = $false

function Enter-LabLock {
    param([Parameter(Mandatory)][string]$What, [int]$TimeoutMinutes = 90)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        try {
            $fs = [IO.File]::Open($script:LabLockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $bytes = [Text.Encoding]::UTF8.GetBytes("$What | $((Get-Date).ToString('o'))")
            $fs.Write($bytes, 0, $bytes.Length); $fs.Dispose()
            $script:LabLockOwned = $true
            return
        }
        catch [IO.IOException] {
            if ((Get-Date) -gt $deadline) { throw "Lab lock still held after $TimeoutMinutes min: $(Get-Content $script:LabLockPath -Raw -ErrorAction SilentlyContinue)" }
            Write-Host "lock held: $(Get-Content $script:LabLockPath -Raw -ErrorAction SilentlyContinue) - waiting 30 s"
            Start-Sleep 30
        }
    }
}

function Exit-LabLock {
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
