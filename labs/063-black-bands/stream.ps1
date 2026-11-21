# Lab 063: what the person sees and what the helper handed Sunshine, at the same time. Opens GpuVM's viewer with the
# labs' own pipe (closing any open viewer), records the stream through it ("record", as the app does) while race.ps1
# runs a load and the probe in the machine, then counts lab 057's black-for-one-frame glitches in the recording and
# reads the helper's lab063 counters. Run elevated.
# Out: out\<Label>-stream.json (+ race.ps1's out\<Label>\)
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Label,
    [int]$Seconds = 60,
    [string]$Load = 'videochurn',
    [switch]$KeepViewer,
    [hashtable]$Race = @{}
)
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $Lab063Root 'tools\latency\common.ps1')
$out = Join-Path $PSScriptRoot 'out'
$row = [ordered]@{ label = $Label; at = (Get-Date).ToString('s'); load = $Load; seconds = $Seconds }
$session = $null
try {
    $launch = (Connect-GpuVM -Name $Name -Viewer 6>$null).viewerLaunch
    $started = Get-Date
    $session = Start-LatencyViewer -Viewer gpuvm -Arguments @($launch.arguments) -Quiet
    $row.firstFrameSec = Wait-LatencyViewerFrame $session -Since $started
    if ($row.firstFrameSec -lt 0) { throw "no picture: $(@($session.Bridge.Events.ToArray()) -join ' ')" }
    Start-Sleep -Seconds 3
    $events = { param($type) @($session.Bridge.Events.ToArray() | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_.type -eq $type }) }
    [void]$session.Bridge.Send((@{ type = 'capture-setup'; replay = $false; seconds = 30; lang = 'es' } | ConvertTo-Json -Compress))
    [void]$session.Bridge.Send('{"type":"record","on":true}')
    $w = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $events 'recording') -and $w.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 200 }
    if (-not (& $events 'recording')) { throw "the viewer didn't start recording: $(@($session.Bridge.Events.ToArray()) -join ' ')" }
    $recStart = Get-Date
    $raceArgs = @{ Name = $Name; Label = $Label; Seconds = $Seconds; Delays = 'fast2'; Pool = 1; Load = $Load; Prio = 'rt'; Cursor = $true; ProbeFirst = $true }
    foreach ($k in $Race.Keys) { $raceArgs[$k] = $Race[$k] }
    $row.probe = & (Join-Path $PSScriptRoot 'race.ps1') @raceArgs
    $row.recordedSec = [int]((Get-Date) - $recStart).TotalSeconds
    [void]$session.Bridge.Send('{"type":"record","on":false}')
    $w.Restart()
    while (-not ($file = & $events 'capture' | Select-Object -Last 1) -and $w.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 300 }
    if (-not $file) { throw 'the viewer saved no recording' }
    $path = Join-Path $env:USERPROFILE "AppData\LocalLow\GpuVM\Viewer\Captures\$($file.file)"
    if (-not (Test-Path $path)) { $path = $file.file }
    $row.file = $path
    $row.stats = Get-LatencyViewerStats $session -LastSeconds $Seconds
    $count = & python -I (Join-Path $PSScriptRoot '..\057-capture-broker\glitches.py') $path
    $row.glitches = $count
    if (($count | Select-Object -First 1) -match 'moving_fps=([\d.]+) .* glitches=(\d+) per_min=([\d.]+)') { $row.movingFps = [double]$Matches[1]; $row.count = [int]$Matches[2]; $row.perMin = [double]$Matches[3] }
}
catch { $row.error = "$_" }
finally {
    # The helper writes its counters every 15 s and is restarted when the viewer leaves: read them first, from every
    # log of this session, once the last interval is written.
    if ($started) {
        Start-Sleep -Seconds 16
        $row.helper = & (Join-Path $PSScriptRoot 'helper-stats.ps1') -Name $Name -Since $started
    }
    if ($session -and -not $KeepViewer) { Stop-Process -Id $session.Process.Id -Force -ErrorAction SilentlyContinue; if ($session.Bridge) { $session.Bridge.Dispose() } }
    $row | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out "$Label-stream.json")
}
"$Label  stream: glitches=$($row.count) ($($row.perMin)/min, moving $($row.movingFps) fps) firstFrame=$($row.firstFrameSec)s error=$($row.error)"
"  probe: $(@($row.probe) | Select-Object -First 1)"
"  helper: $($row.helper | ConvertTo-Json -Compress)"
