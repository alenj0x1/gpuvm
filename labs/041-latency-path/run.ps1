# Lab 041: the whole stream path in one pass per variant, to find and remove latency.
# Each variant is a setup and an undo (scriptblocks), so any hypothesis (the GpuVM app open, a Sunshine setting, the
# virtual display) is tried without a new lab. Per variant and round, with GpuVM's viewer (as the app starts it):
#   gpu       host GPU load during the stream (nvidia-smi, the GPU the VM shares through GPU-P)
#   stats     the viewer's own numbers: received/rendered FPS, decode, host processing and network latency
#   motion    how often a bar drawn on the GPU in the VM (Edge, requestAnimationFrame) moves on this screen
#   input     key, click and move latency to the input target (tools/latency/input-target.ps1)
# Variants run in interleaved rounds. Takes over the screen, mouse and keyboard. Run elevated, in the user's session:
#   pwsh -File labs/041-latency-path/run.ps1 -Name win-gpu -Variants baseline, app-closed
param(
    [Parameter(Mandatory)][string]$Name,
    [string[]]$Variants = @('baseline'),
    # Extra variants: @{ Name = '...'; Setup = { param($vm) ... }; Undo = { param($vm) ... }; Client = @{ ... } }.
    [hashtable[]]$Custom,
    [int]$Rounds = 2,
    [double]$MotionSeconds = 10,
    [int]$Samples = 25,
    [switch]$SkipInput,
    [switch]$Force,
    [string]$Out = (Join-Path $PSScriptRoot "out\run-$(Get-Date -Format 'yyyyMMdd-HHmmss').json")
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
$tools = Join-Path $PSScriptRoot '..\..\tools\latency'
. (Join-Path $tools 'common.ps1')
. (Join-Path $tools 'input-meter.ps1')
. (Join-Path $tools 'motion-meter.ps1')
. (Join-Path $PSScriptRoot 'variants.ps1')

$vm = Get-LatencyVM -Name $Name
$table = Get-Lab041Variants
$list = @(foreach ($n in $Variants) { if (-not $table.Contains($n)) { throw "Unknown variant '$n'. Known: $($table.Keys -join ', ')" }; [pscustomobject]$table[$n] })
if ($Custom) { $list += $Custom | ForEach-Object { [pscustomobject]$_ } }

$state = & $vm.Module { param($n) Get-GpuVMState -Name $n } $Name
$saved = $state['config']['streaming']['client']
$results = [System.Collections.Generic.List[object]]::new()
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

function Get-GpuLoad([double]$Seconds) {
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) { return $null }
    $n = [math]::Max(1, [int]($Seconds * 2))
    $v = @(1..$n | ForEach-Object { [int](& $smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | Select-Object -First 1); Start-Sleep -Milliseconds 500 })
    [math]::Round(($v | Measure-Object -Average).Average, 1)
}

try {
    for ($round = 1; $round -le $Rounds; $round++) {
        foreach ($variant in $list) {
            Stop-LatencyViewers
            $row = [ordered]@{ variant = $variant.Name; round = $round; startedAt = (Get-Date).ToString('o') }
            try {
                # Inside the try: a setup that fails halfway is still undone.
                if ($variant.PSObject.Properties['Setup'] -and $variant.Setup) { & $variant.Setup $vm | Out-Host }
                $row.gpuIdlePct = Get-GpuLoad 3
                $client = [ordered]@{}
                foreach ($k in $saved.Keys) { $client[$k] = $saved[$k] }
                $client['displayMode'] = 'borderless'
                if ($variant.PSObject.Properties['Client'] -and $variant.Client) { foreach ($k in $variant.Client.Keys) { $client[$k] = $variant.Client[$k] } }
                $fps = [int](& $vm.Module { param($f) Resolve-GpuVMStreamFps $f } $client['fps'])
                $arguments = & $vm.Module { param($a, $c) Get-MoonlightStreamArguments -Address $a -Client $c } $vm.Address $client
                $row.arguments = $arguments -join ' '

                Start-Lab041Target $vm 'gpu'
                $started = Get-Date
                $session = Start-LatencyViewer -Viewer gpuvm -Arguments $arguments
                $row.firstFrameSec = Wait-LatencyViewerFrame $session -Since $started
                $session.Process.Refresh()
                $window = $session.Process.MainWindowHandle
                if (-not [GpuVMInputMeter]::BringToFront($window)) { 'the viewer is not in front' | Write-Host }
                Start-Sleep -Milliseconds 500
                $wait = [Diagnostics.Stopwatch]::StartNew(); $row.pictureSec = -1
                while ($wait.Elapsed.TotalSeconds -lt 60) {
                    $probe = Measure-Motion -Bounds $screen -Fps $fps -Seconds 0.5
                    if (-not $probe.PSObject.Properties['error']) { $row.pictureSec = [math]::Round(((Get-Date) - $started).TotalSeconds, 1); break }
                }
                Start-Sleep -Seconds 2
                $row.motion = Measure-Motion -Bounds $screen -Fps $fps -Seconds $MotionSeconds
                $row.gpuStreamPct = Get-GpuLoad 3
                $row.stats = Get-LatencyViewerStats $session -LastSeconds ([int]$MotionSeconds)

                if (-not $SkipInput) {
                    Start-Lab041Target $vm 'input'
                    Start-Sleep -Seconds 3
                    [void][GpuVMInputMeter]::BringToFront($window)
                    $bounds = [System.Drawing.Rectangle]::new($screen.Left, $screen.Top, $screen.Width, $screen.Height)
                    [void][GpuVMInputMeter]::SetCursorPos($bounds.Left + $bounds.Width / 2, $bounds.Top + $bounds.Height / 6)
                    $click = Get-InputSquarePoint -Bounds $bounds -Index 1
                    $w2 = [Diagnostics.Stopwatch]::StartNew()
                    while ($w2.Elapsed.TotalSeconds -lt 30 -and [GpuVMInputMeter]::Measure(1, $click.X, $click.Y, 500, $window) -lt 0) { Start-Sleep -Milliseconds 300 }
                    $null = Measure-InputLatency -Bounds $bounds -Window $window -Kinds click, key, move -Samples 3
                    $row.input = @(Measure-InputLatency -Bounds $bounds -Window $window -Kinds key, click, move -Samples $Samples | Select-Object kind, medianMs, p95Ms, meanMs, minMs, misses, raw)
                }
                Stop-LatencyStream $session -VM $vm
                if ($session.Bridge) { $session.Bridge.Dispose() }
            }
            catch { $row.error = "$_"; "$($variant.Name) r$round : $_" | Write-Host }
            finally {
                if ($variant.PSObject.Properties['Undo'] -and $variant.Undo) { try { & $variant.Undo $vm | Out-Host } catch { "undo failed: $_" | Write-Host } }
            }
            $results.Add([pscustomobject]$row)
            $m = $row.motion; $s = $row.stats
            $in = if ($row.input) { ($row.input | ForEach-Object { "$($_.kind) $($_.medianMs)" }) -join ', ' } else { '-' }
            "{0} r{1}: gpu idle {2} % stream {3} % | updates/s {4} stutter {5} % | rx {6} fps shown {7} fps host {8} ms decode {9} ms net {10} ms | input {11}" -f $variant.Name, $round, $row.gpuIdlePct, $row.gpuStreamPct, $m.updatesPerSec, $m.stutterPct, $s.receivedFps, $s.renderedFps, $s.hostLatencyMs, $s.decodeMs, $s.networkLatencyMs, $in | Write-Host
        }
    }
}
finally {
    Stop-LatencyViewers
    Start-Lab041Target $vm 'none'
    [pscustomobject]@{ measuredAt = (Get-Date).ToString('o'); vm = $Name; hostScreen = "$($screen.Width)x$($screen.Height)"; results = @($results) } |
        ConvertTo-Json -Depth 7 | Set-Content -Path $Out -Encoding utf8
    "saved $Out" | Write-Host
}
