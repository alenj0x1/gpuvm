# Lab 044, part 3: what recording and the last-30-s buffer cost a live stream, with GpuVM's viewer as built here
# (repo viewer\GpuVMViewer.exe) driven through its pipe like the app does (tools/latency, method of labs 020/021/041).
# Variants in interleaved rounds:
#   baseline   nothing on
#   record     recording to MP4 (H.264/HEVC/AV1 as received + AAC)
#   replay     the last 30 s kept in memory
#   both       recording and the buffer
# Per variant and round: motion (updates/s and stutter of a GPU-drawn bar in the VM), the viewer's own numbers
# (received/rendered FPS, decode, host and network latency), key/click/move latency, the viewer's memory and CPU, and
# at the end the files it wrote (size per minute, duration, playable in ffmpeg and Windows' Media Foundation). One
# screenshot per round is timed (command to file announced). Takes the shared lab lock (C:\GpuVM\.lab-lock).
# Takes over the screen, mouse and keyboard for a few minutes. Run elevated, in the user's session:
#   pwsh -File labs/044-capture-clips/run.ps1 -Name win11-pruebas
param(
    [Parameter(Mandatory)][string]$Name,
    [string[]]$Variants = @('baseline', 'record', 'replay', 'both'),
    [int]$Rounds = 2,
    [double]$MotionSeconds = 20,
    [int]$Samples = 40,
    [switch]$SkipInput,
    [switch]$Force,
    [string]$Session = 'capture-clips',
    [string]$Out = (Join-Path $PSScriptRoot "out\run-$(Get-Date -Format 'yyyyMMdd-HHmmss').json")
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
$tools = Join-Path $PSScriptRoot '..\..\tools\latency'
. (Join-Path $tools 'common.ps1')
. (Join-Path $tools 'input-meter.ps1')
. (Join-Path $tools 'motion-meter.ps1')
. (Join-Path $PSScriptRoot '..\041-latency-path\variants.ps1')
$bin = Join-Path $PSScriptRoot 'out\bin'
$captures = Join-Path $env:USERPROFILE 'AppData\LocalLow\GpuVM\Viewer\Captures'

# The shared lock: the PC's GPU and VMs are shared by several sessions.
$lock = 'C:\GpuVM\.lab-lock'
$waited = [Diagnostics.Stopwatch]::StartNew()
while ($true) {
    try { $fs = [IO.File]::Open($lock, 'CreateNew', 'Write'); $w = [IO.StreamWriter]::new($fs); $w.Write("$Session lab 044 $(Get-Date -Format o)"); $w.Dispose(); break }
    catch [IO.IOException] {
        if ($waited.Elapsed.TotalMinutes -gt 20) { throw "The lab lock is held: $(Get-Content $lock -ErrorAction SilentlyContinue)" }
        "lock held by: $(Get-Content $lock -ErrorAction SilentlyContinue); waiting" | Write-Host
        Start-Sleep -Seconds 30
    }
}

$results = [System.Collections.Generic.List[object]]::new()
try {
    $hostGpuPct = Assert-LatencyGpuIdle -Force:$Force
    "host GPU before: $hostGpuPct %" | Write-Host
    $vm = Get-LatencyVM -Name $Name
    $state = & $vm.Module { param($n) Get-GpuVMState -Name $n } $Name
    $client = [ordered]@{}
    foreach ($k in $state['config']['streaming']['client'].Keys) { $client[$k] = $state['config']['streaming']['client'][$k] }
    $client['displayMode'] = 'borderless'
    $fps = [int](& $vm.Module { param($f) Resolve-GpuVMStreamFps $f } $client['fps'])
    $arguments = & $vm.Module { param($a, $c) Get-MoonlightStreamArguments -Address $a -Client $c } $vm.Address $client
    $sw, $sh = [int[]]("$($client['resolution'])" -split 'x')

    function Get-VideoBounds([IntPtr]$Window) {
        $c = [GpuVMInputMeter]::ClientBounds($Window)
        $scale = [math]::Min($c[2] / $sw, $c[3] / $sh)
        $w = [int]($sw * $scale); $h = [int]($sh * $scale)
        [System.Drawing.Rectangle]::new($c[0] + [int](($c[2] - $w) / 2), $c[1] + [int](($c[3] - $h) / 2), $w, $h)
    }
    # The viewer's messages of one type since a moment (the bridge keeps them all).
    function Wait-Event($session, [string]$Type, [int]$TimeoutSec = 60, [int]$Skip = 0) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while ($watch.Elapsed.TotalSeconds -lt $TimeoutSec) {
            $hits = @($session.Bridge.Events.ToArray() | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_.type -eq $Type })
            if ($hits.Count -gt $Skip) { return $hits[$Skip] }
            Start-Sleep -Milliseconds 100
        }
        $null
    }
    # Checks a file the viewer wrote (ffprobe, a full decode with ffmpeg, Media Foundation), then deletes it.
    function Test-CaptureFile([string]$File) {
        $path = Join-Path $captures $File
        if (-not (Test-Path $path)) { return [ordered]@{ file = $File; missing = $true } }
        $r = [ordered]@{ file = $File; bytes = (Get-Item $path).Length }
        if ($File -like '*.mp4') {
            $probe = & ffprobe -v error -show_entries 'format=duration:stream=codec_name,width,height,color_transfer,nb_frames' -of json $path | ConvertFrom-Json
            $r.durationS = [double]$probe.format.duration
            $r.streams = @($probe.streams | ForEach-Object { "$($_.codec_name) $($_.width)x$($_.height)" })
            $r.ffmpegErrorLines = (& ffmpeg -hide_banner -v error -i $path -fps_mode passthrough -f null - 2>&1 | Measure-Object -Line).Lines
            $r.mf = (& (Join-Path $bin 'mfprobe.exe') $path) | ConvertFrom-Json
            if ($r.durationS -gt 0) { $r.mbPerMin = [math]::Round($r.bytes / 1MB / $r.durationS * 60, 1) }
        }
        else {
            Add-Type -AssemblyName System.Drawing
            $img = [System.Drawing.Image]::FromFile($path)
            $r.png = "$($img.Width)x$($img.Height)"
            $img.Dispose()
        }
        Remove-Item $path -Force
        $r
    }

    for ($round = 1; $round -le $Rounds; $round++) {
        foreach ($variant in $Variants) {
            Stop-LatencyViewers
            $row = [ordered]@{ variant = $variant; round = $round; startedAt = (Get-Date).ToString('o'); arguments = $arguments -join ' ' }
            try {
                Start-Lab041Target $vm 'gpu'
                $started = Get-Date
                $session = Start-LatencyViewer -Viewer gpuvm -Arguments $arguments
                $row.firstFrameSec = Wait-LatencyViewerFrame $session -Since $started
                $session.Process.Refresh()
                $window = $session.Process.MainWindowHandle
                [void][GpuVMInputMeter]::BringToFront($window)
                Start-Sleep -Milliseconds 500
                $video = Get-VideoBounds $window
                $wait = [Diagnostics.Stopwatch]::StartNew()
                while ($wait.Elapsed.TotalSeconds -lt 60) {
                    $probe = Measure-Motion -Bounds $video -Fps $fps -Seconds 0.5
                    if (-not $probe.PSObject.Properties['error']) { break }
                }
                $replay = $variant -in 'replay', 'both'
                $record = $variant -in 'record', 'both'
                [void]$session.Bridge.Send((@{ type = 'capture-setup'; replay = $replay; seconds = 30; lang = 'es' } | ConvertTo-Json -Compress))
                if ($record) { [void]$session.Bridge.Send('{"type":"record","on":true}') }
                $recordOn = if ($record) { Wait-Event $session 'recording' 10 } else { $null }
                # The buffer fills for its 30 s (and the recording runs) before measuring.
                Start-Sleep -Seconds 32
                $proc = $session.Process; $proc.Refresh()
                $cpu0 = $proc.TotalProcessorTime; $t0 = Get-Date
                $row.motion = Measure-Motion -Bounds $video -Fps $fps -Seconds $MotionSeconds
                $proc.Refresh()
                $row.viewerCpuPct = [math]::Round(($proc.TotalProcessorTime - $cpu0).TotalMilliseconds / ((Get-Date) - $t0).TotalMilliseconds / [Environment]::ProcessorCount * 100, 2)
                $row.viewerPrivateMB = [math]::Round($proc.PrivateMemorySize64 / 1MB, 1)
                $row.viewerWorkingSetMB = [math]::Round($proc.WorkingSet64 / 1MB, 1)
                $row.stats = Get-LatencyViewerStats $session -LastSeconds ([int]$MotionSeconds)

                if (-not $SkipInput) {
                    Start-Lab041Target $vm 'input'
                    Start-Sleep -Seconds 3
                    [void][GpuVMInputMeter]::BringToFront($window)
                    [void][GpuVMInputMeter]::SetCursorPos($video.Left + $video.Width / 2, $video.Top + $video.Height / 6)
                    $click = Get-InputSquarePoint -Bounds $video -Index 1
                    $w2 = [Diagnostics.Stopwatch]::StartNew()
                    while ($w2.Elapsed.TotalSeconds -lt 30 -and [GpuVMInputMeter]::Measure(1, $click.X, $click.Y, 500, $window) -lt 0) { Start-Sleep -Milliseconds 300 }
                    $null = Measure-InputLatency -Bounds $video -Window $window -Kinds click, key, move -Samples 3
                    $row.input = @(Measure-InputLatency -Bounds $video -Window $window -Kinds key, click, move -Samples $Samples | Select-Object kind, medianMs, p95Ms, meanMs, minMs, misses, raw)
                }

                # A screenshot: from the command to the PNG announced.
                $shotWatch = [Diagnostics.Stopwatch]::StartNew()
                [void]$session.Bridge.Send('{"type":"screenshot"}')
                $shot = Wait-Event $session 'capture' 15
                $row.screenshot = if ($shot) { [ordered]@{ ms = $shotWatch.ElapsedMilliseconds; check = Test-CaptureFile $shot.file } } else { 'none' }
                $files = 1
                if ($replay) {
                    $saveWatch = [Diagnostics.Stopwatch]::StartNew()
                    [void]$session.Bridge.Send('{"type":"replay-save"}')
                    $clip = Wait-Event $session 'capture' 60 -Skip $files
                    $row.replay = if ($clip) { [ordered]@{ saveMs = $saveWatch.ElapsedMilliseconds; durationMs = $clip.durationMs; check = Test-CaptureFile $clip.file } } else { 'none' }
                    $files++
                }
                if ($record) {
                    $stopWatch = [Diagnostics.Stopwatch]::StartNew()
                    [void]$session.Bridge.Send('{"type":"record","on":false}')
                    $file = Wait-Event $session 'capture' 120 -Skip $files
                    $row.recording = if ($file) { [ordered]@{ stopMs = $stopWatch.ElapsedMilliseconds; durationMs = $file.durationMs; check = Test-CaptureFile $file.file } } else { 'none' }
                }
                $row.errors = @($session.Bridge.Events.ToArray() | Where-Object { $_ -match '"capture-error"' })
                Stop-LatencyStream $session -VM $vm
                if ($session.Bridge) { $session.Bridge.Dispose() }
            }
            catch { $row.error = "$_"; "$variant r$round : $_" | Write-Host }
            $results.Add([pscustomobject]$row)
            $m = $row.motion; $s = $row.stats
            $in = if ($row.input) { ($row.input | ForEach-Object { "$($_.kind) $($_.medianMs)/$($_.p95Ms)" }) -join ', ' } else { '-' }
            "{0} r{1}: updates/s {2} stutter {3} % | rx {4} shown {5} fps decode {6} ms host {7} ms | cpu {8} % mem {9} MB | input {10}" -f $variant, $round, $m.updatesPerSec, $m.stutterPct, $s.receivedFps, $s.renderedFps, $s.decodeMs, $s.hostLatencyMs, $row.viewerCpuPct, $row.viewerPrivateMB, $in | Write-Host
        }
    }
}
finally {
    Stop-LatencyViewers
    try { Start-Lab041Target $vm 'none' } catch { }
    [pscustomobject]@{ measuredAt = (Get-Date).ToString('o'); vm = $Name; results = @($results) } | ConvertTo-Json -Depth 8 | Set-Content -Path $Out -Encoding utf8
    "saved $Out" | Write-Host
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
}
