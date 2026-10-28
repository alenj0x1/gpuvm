# Opens Moonlight with its performance overlay for each variant and saves screenshots of the overlay,
# so its numbers (host processing, network, decoding, queue and rendering times, dropped frames) can be recorded.
# Before each variant the VM's virtual display is set to that frame rate, as "Start and open" does.
# Run as administrator, with the latency target running in the VM (start-target.ps1).
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$App = 'Desktop',
    [string[]]$Only,
    [int]$WarmupSec = 25,
    [int]$Shots = 3,
    [int]$IntervalSec = 5
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$vm = Get-LatencyVM -Name $Name
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

foreach ($variant in Get-LatencyVariants | Where-Object { -not $Only -or $_.Name -in $Only }) {
    $started = Get-Date
    $session = Start-LatencyStream -VM $vm -Variant $variant -App $App -Overlay
    $visibleSec = Wait-LatencyStreamVisible -Since $started
    Start-Sleep -Seconds 5
    for ($i = 1; $i -le $Shots; $i++) {
        Save-ScreenRegion -Path (Join-Path $OutDir "$($variant.Name)-$i.png") -Width 760 -Height 520
        Start-Sleep -Seconds $IntervalSec
    }
    Stop-LatencyStream $session -VM $vm
    "$($variant.Name) done"
}
