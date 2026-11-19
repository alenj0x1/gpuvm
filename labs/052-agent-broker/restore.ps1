# Puts the installed GpuVM service back as it was before a lab 052 run (gpuvm-host.exe and Agent.ps1 from the
# backup the run made) and deletes the machines a run left behind (-Machines). Uses this branch's bounded stop.
# Under the shared lab lock. Run elevated.
param([string[]]$Machines = @(), [string]$Session = 'agent-broker')
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$backupDir = 'C:\GpuVM\lab052\installed'
$boundedStop = 'C:\GpuVM\lab052\gpuvm-host-stop.exe'
& (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What 'lab 052: put the installed GpuVM service back' -Me $Session -MaxMinutes 120
if ($LASTEXITCODE) { throw 'no lock' }
try {
    Import-Module (Join-Path $env:ProgramFiles 'GpuVM\gpuvm\src\GpuVM\GpuVM.psd1') -Force
    foreach ($m in $Machines) {
        if (-not (Get-VM -Name $m -ErrorAction SilentlyContinue)) { continue }
        Stop-VM -Name $m -TurnOff -Force -ErrorAction SilentlyContinue
        $w = [Diagnostics.Stopwatch]::StartNew()
        while ((Get-VM -Name $m -ErrorAction SilentlyContinue) -and (Get-VM -Name $m).State -ne 'Off' -and $w.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Seconds 1 }
        if (Get-VM -Name $m -ErrorAction SilentlyContinue) { Remove-GpuVM -Name $m -DeleteDisk -Confirm:$false }
        "$m deleted"
    }
    $w = [Diagnostics.Stopwatch]::StartNew()
    Start-Process $boundedStop -ArgumentList 'stop' -Wait -WindowStyle Hidden
    "service stopped in $([math]::Round($w.Elapsed.TotalMilliseconds)) ms: $((Get-Service GpuVM).Status)"
    Copy-Item (Join-Path $backupDir 'gpuvm-host.exe') (Join-Path $env:ProgramFiles 'GpuVM\gpuvm-host.exe') -Force
    Copy-Item (Join-Path $backupDir 'Agent.ps1') (Join-Path $env:ProgramFiles 'GpuVM\gpuvm\src\GpuVM\Private\Agent.ps1') -Force
    Start-Service GpuVM
    "installed files back; service $((Get-Service GpuVM).Status); host $((Get-FileHash (Join-Path $env:ProgramFiles 'GpuVM\gpuvm-host.exe')).Hash.Substring(0, 12))"
}
finally {
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    'lock released'
}
