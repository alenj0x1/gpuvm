# End-to-end latency meter: key press → the VM reacts → Sunshine captures and encodes → Moonlight decodes and shows it.
# For each variant it opens Moonlight, presses Scroll Lock (forwarded to the VM) and times how long the center
# square of the latency target (target.ps1, running in the VM) takes to change between black and white on this screen.
# What the monitor itself adds afterwards is not included. Run as administrator, same session as Moonlight.
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$OutFile,
    [string]$App = 'Desktop',
    [string[]]$Only,
    [int]$Samples = 40,
    [int]$WarmupSec = 25,
    [int]$TimeoutMs = 1000
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$vm = Get-LatencyVM -Name $Name


function Get-Percentile([double[]]$Values, [double]$P) {
    $sorted = $Values | Sort-Object
    $index = [math]::Min($sorted.Count - 1, [math]::Max(0, [math]::Ceiling($P * $sorted.Count) - 1))
    [math]::Round($sorted[$index], 1)
}

$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$px = $bounds.Left + [int]($bounds.Width / 2)
$py = $bounds.Top + [int]($bounds.Height / 2)
$random = [System.Random]::new()
$results = foreach ($variant in Get-LatencyVariants | Where-Object { -not $Only -or $_.Name -in $Only }) {
    $started = Get-Date
    $session = Start-LatencyStream -VM $vm -Variant $variant -App $App
    $visibleSec = Wait-LatencyStreamVisible -Since $started
    Start-Sleep -Seconds 5
    # Keyboard input goes to the foreground window: make it Moonlight, and close anything open in the VM (Esc).
    $session.Process.Refresh()
    [void][GpuVMLatency]::SetForegroundWindow($session.Process.MainWindowHandle)
    Start-Sleep -Milliseconds 300
    [GpuVMLatency]::Key(0x1B)
    Start-Sleep -Milliseconds 800
    $times = [System.Collections.Generic.List[double]]::new()
    $misses = 0
    for ($i = 0; $i -lt $Samples; $i++) {
        $lit = [GpuVMLatency]::Brightness($px, $py) -gt 128
        $ms = [GpuVMLatency]::Measure($px, $py, -not $lit, $TimeoutMs)
        if ($ms -lt 0) { $misses++ } else { $times.Add($ms) }
        # Random pause so clicks don't line up with the stream's frame timing.
        Start-Sleep -Milliseconds (250 + $random.Next(0, 250))
    }
    Stop-LatencyStream $session -VM $vm
    $row = [ordered]@{
        variant = $variant.Name
        fps     = $variant.Fps
        vsync   = $variant.VSync
        display = $session.Display
        samples = $times.Count
        misses  = $misses
        firstFrameSec = $visibleSec
    }
    if ($times.Count) {
        $row.minMs = [math]::Round(($times | Measure-Object -Minimum).Minimum, 1)
        $row.medianMs = Get-Percentile $times 0.5
        $row.p95Ms = Get-Percentile $times 0.95
        $row.meanMs = [math]::Round(($times | Measure-Object -Average).Average, 1)
    }
    $row.raw = @($times | ForEach-Object { [math]::Round($_, 2) })
    [pscustomobject]$row
    "$($variant.Name): median $($row.medianMs) ms, p95 $($row.p95Ms) ms, misses $misses" | Write-Host
}
[pscustomobject]@{
    measuredAt = (Get-Date).ToString('o')
    vm         = $Name
    resolution = '1920x1080'
    hostScreen = "$($bounds.Width)x$($bounds.Height)"
    variants   = @($results)
} | ConvertTo-Json -Depth 5 | Set-Content -Path $OutFile -Encoding utf8
