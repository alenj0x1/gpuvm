# Lab 053 part 6 (security fixes) on a real disposable, under the shared lab lock (queue-aware).
#   pwsh -NoProfile -File labs/053-mcp/security-real.ps1 [-Template agent-tpl]
param([ValidatePattern('^[\w-]{1,40}$')][string]$Template = 'agent-tpl', [string]$Exe = 'C:\Program Files\GpuVM\gpuvm.exe')
$ErrorActionPreference = 'Stop'
$me = 'agent-mcp'
$lockFile = 'C:\GpuVM\.lab-lock'
& (Join-Path $PSScriptRoot '..\042-admin-dock\take-lock.ps1') -What "lab 053 security fixes (one disposable)" -Me $me -MaxMinutes 240
if ($LASTEXITCODE -ne 0) { throw 'No lab lock.' }
$vmsBefore = @(Get-VM | ForEach-Object Name)
try {
    Import-Module (Join-Path (Split-Path $Exe) 'gpuvm\src\GpuVM\GpuVM.psd1') -Force -DisableNameChecking
    if (-not (@(Get-GpuVMTemplate) | Where-Object name -eq $Template)) { throw "The template $Template doesn't exist (yet)." }
    $freeGB = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)
    "free memory $freeGB GB"
    if ($freeGB -lt 4.8) { throw "Only $freeGB GB free: not enough for a 4 GB disposable." }
    python (Join-Path $PSScriptRoot 'security.py') --exe $Exe --template $Template
    "security.py exit $LASTEXITCODE"
}
finally {
    $left = @(Get-VM | Where-Object { $_.Name -notin $vmsBefore -and $_.Name -like "$Template-*" })
    foreach ($vm in $left) { "deleting leftover $($vm.Name)"; Stop-VM -Name $vm.Name -TurnOff -Force -ErrorAction SilentlyContinue }
    if ($left) {
        Import-Module (Join-Path (Split-Path $Exe) 'gpuvm\src\GpuVM\GpuVM.psd1') -Force -DisableNameChecking
        Remove-GpuVMDisposable -Confirm:$false
    }
    if ((Test-Path $lockFile) -and ((Get-Content $lockFile -Raw) -like "$me |*")) { Remove-Item -LiteralPath $lockFile -Force }
    'lab lock released'
}
