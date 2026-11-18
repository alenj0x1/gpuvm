# Lab 045 helper: a second Windows for another session's test (front 2's "Enviar a"). Frees the Windows 10 base cache
# (it is made again on the next ISO install) so a normal copy of lab045-tpl fits GpuVM's disk-room rule, then creates
# lab045-win2 from it (3 GB, 4 threads, not started). Takes the shared lab lock (queue-aware). Elevated PowerShell 7.
param([string]$Name = 'lab045-win2', [string]$Template = 'lab045-tpl')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lock.ps1')
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
Enter-LabLock "disks-backup | crear $Name (segunda Windows para files-clipboard) (~3 min)"
try {
    foreach ($base in @(Get-GpuVMBase)) {
        Write-Host "removing base $($base['key']) ($($base['edition']))"
        Remove-GpuVMBase -Key $base['key'] -Confirm:$false
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    New-GpuVM -Name $Name -Template $Template -Profile balanced -Override @{ vm = @{ memoryGB = 4; cpu = @{ count = 4 } } } -Confirm:$false | Out-Null
    Write-Host "created $Name in $([math]::Round($sw.Elapsed.TotalSeconds, 1)) s"
}
finally { Exit-LabLock }
