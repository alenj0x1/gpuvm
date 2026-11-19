# Waits (without the lab lock or a queue place, so nobody waits on it) until a template made after -After exists,
# then takes the next turn (first in C:\GpuVM\.lab-queue) and runs security-real.ps1.
#   pwsh -NoProfile -File labs/053-mcp/security-when-ready.ps1 -After '2026-11-19T07:40:00'
param([ValidatePattern('^[\w-]{1,40}$')][string]$Template = 'agent-tpl', [Parameter(Mandatory)][datetime]$After, [int]$MaxHours = 6,
    [string]$Exe = 'C:\Program Files\GpuVM\gpuvm.exe')
$ErrorActionPreference = 'Stop'
$me = 'agent-mcp'
$queue = 'C:\GpuVM\.lab-queue'
$end = (Get-Date).AddHours($MaxHours)
$module = Join-Path (Split-Path $Exe) 'gpuvm\src\GpuVM\GpuVM.psd1'
while ($true) {
    if ((Get-Date) -gt $end) { throw "No $Template made after $After within $MaxHours h." }
    $made = pwsh -NoProfile -Command "Import-Module '$module' -Force -DisableNameChecking; (@(Get-GpuVMTemplate) | Where-Object name -eq '$Template' | Select-Object -First 1).createdAt"
    $at = [datetime]::MinValue
    if ($made -and [datetime]::TryParse(($made | Select-Object -Last 1), [ref]$at) -and $at -gt $After) { break }
    Start-Sleep -Seconds 60
}
"$Template made at $at"
# The next turn: first in the queue (after whoever holds the lock now).
$lines = @(if (Test-Path $queue) { Get-Content $queue | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne $me } })
Set-Content -LiteralPath $queue -Value (@($me) + $lines)
& (Join-Path $PSScriptRoot 'security-real.ps1') -Template $Template -Exe $Exe
