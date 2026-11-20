# Lab 052: GpuVM's viewer black on agent machines. Runs viewer-black.mjs (lab 054's refresh.mjs, with Sunshine's log
# dumped before the copy is deleted) under the shared lab lock, then deletes any copy left. GpuVM's window shows on
# screen during the run (the viewer opens in it). Run elevated.
param([string]$Session = 'agent-broker', [int]$Connects = 10, [string]$Label = 'before')
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
function Line($what) { Write-Host "$(Get-Date -Format HH:mm:ss.fff) $what" }
& (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What "lab 052: viewer black on agent machines ($Label)" -Me $Session -MaxMinutes 180
if ($LASTEXITCODE) { throw 'no lock' }
$before = @(Get-VM | ForEach-Object Name)
try { node (Join-Path $PSScriptRoot 'viewer-black.mjs') 'template:agent-tpl' $Connects }
finally {
    Import-Module (Join-Path $env:ProgramFiles 'GpuVM\gpuvm\src\GpuVM\GpuVM.psd1') -Force
    foreach ($vm in @(Get-VM | Where-Object { $_.Name -notin $before })) {
        try { Stop-VM -Name $vm.Name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $vm.Name -DeleteDisk -Confirm:$false; Line "left-over $($vm.Name) deleted" }
        catch { Line "couldn't delete $($vm.Name): $($_.Exception.Message)" }
    }
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Line 'lock released'
}
