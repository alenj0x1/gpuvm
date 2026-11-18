# Lab 045: export/import offline, then the real-VM test, in one turn of the shared lock (the queue is not given up
# between them). Elevated PowerShell 7.
param([string[]]$Labs = @('transfer-offline.ps1', 'real-vm.ps1'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lock.ps1')
Enter-LabLock "disks-backup | lab 045: $($Labs -join ', ') (win-gpu apagada mientras corre, la enciendo al terminar)"
$env:LAB045_LOCK_HELD = '1'
try {
    # One lab failing doesn't skip the other.
    foreach ($lab in $Labs) {
        try { & (Join-Path $PSScriptRoot $lab) } catch { Write-Warning "${lab}: $($_.Exception.Message)" }
    }
}
finally {
    Remove-Item Env:\LAB045_LOCK_HELD -ErrorAction SilentlyContinue
    Exit-LabLock
}
