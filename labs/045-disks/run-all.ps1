# Lab 045: export/import offline, then the real-VM test, in one turn of the shared lock (the queue is not given up
# between them). Elevated PowerShell 7.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lock.ps1')
Enter-LabLock 'disks-backup | lab 045: export/import y luego VM real (win-gpu apagada ~40 min, la enciendo al terminar)'
$env:LAB045_LOCK_HELD = '1'
try {
    # One lab failing doesn't skip the other.
    try { & (Join-Path $PSScriptRoot 'transfer-offline.ps1') } catch { Write-Warning "transfer-offline: $($_.Exception.Message)" }
    try { & (Join-Path $PSScriptRoot 'real-vm.ps1') } catch { Write-Warning "real-vm: $($_.Exception.Message)" }
}
finally {
    Remove-Item Env:\LAB045_LOCK_HELD -ErrorAction SilentlyContinue
    Exit-LabLock
}
