# Lab 021: does Sunshine's capture mode (WGC, the default since lab 026, or DDX) limit how often the picture moves?
# Interleaved rounds (ddx, wgc, ddx, wgc...), each running gdi-vs-gpu.ps1 for one round with GpuVM's viewer. The
# VM's capture mode is switched with Set-GpuVMCapture (restarts Sunshine) and put back as it was in `finally`.
# Only reads the screen. Run elevated: pwsh -File labs/021-stream-smoothness/capture-ab.ps1 -Name win-gpu
param([Parameter(Mandatory)][string]$Name, [int]$Rounds = 2, [double]$Seconds = 15)
$ErrorActionPreference = 'Stop'
$tools = Join-Path $PSScriptRoot '..\..\tools\latency'
. (Join-Path $tools 'common.ps1')
$vm = Get-LatencyVM -Name $Name
$before = (& $vm.Module { param($n) Get-GpuVMState -Name $n } $Name)['config']['streaming']['captureMode']
if (-not $before) { $before = 'wgc' }
"capture before: $before" | Write-Host
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
try {
    for ($round = 1; $round -le $Rounds; $round++) {
        foreach ($mode in 'ddx', 'wgc') {
            Stop-LatencyViewers
            $null = Set-GpuVMCapture -Name $Name -Mode $mode
            # Sunshine restarts in the new mode (service for ddx, the user's logon task for wgc).
            & $vm.Module { param($a, $c) Wait-SunshineReady -Address $a -Credential $c -TimeoutSec 120 -Message 'Sunshine' } $vm.Address $vm.Sunshine | Out-Null
            Start-Sleep -Seconds 3
            "== $mode r$round" | Write-Host
            & (Join-Path $PSScriptRoot 'gdi-vs-gpu.ps1') -Name $Name -Rounds 1 -Seconds $Seconds -Out (Join-Path $PSScriptRoot "out\capture-ab-$stamp-$mode-r$round.json")
        }
    }
}
finally {
    Stop-LatencyViewers
    $null = Set-GpuVMCapture -Name $Name -Mode $before
    "capture back to $before" | Write-Host
}
