# Lab 052: two agent machines at once (two.py drives two MCP servers). Takes the shared lab lock, runs it with the
# installed gpuvm.exe, and afterwards deletes any copy it left (names come from its report). Run elevated.
param([string]$Session = 'agent-broker', [int]$Rounds = 30)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
function Line($what) { Write-Host "$(Get-Date -Format HH:mm:ss.fff) $what" }
& (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What 'lab 052: two agent machines at once' -Me $Session -MaxMinutes 180
if ($LASTEXITCODE) { throw 'no lock' }
$before = @(Get-VM | ForEach-Object Name)
try {
    python (Join-Path $PSScriptRoot 'two.py') --exe (Join-Path $env:ProgramFiles 'GpuVM\gpuvm.exe') --rounds $Rounds
}
finally {
    # Anything new that is still there (a failed destroy): deleted.
    Import-Module (Join-Path $env:ProgramFiles 'GpuVM\gpuvm\src\GpuVM\GpuVM.psd1') -Force
    foreach ($vm in @(Get-VM | Where-Object { $_.Name -notin $before })) {
        try { Stop-VM -Name $vm.Name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $vm.Name -DeleteDisk -Confirm:$false; Line "left-over $($vm.Name) deleted" }
        catch { Line "couldn't delete $($vm.Name): $($_.Exception.Message)" }
    }
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Line 'lock released'
}
