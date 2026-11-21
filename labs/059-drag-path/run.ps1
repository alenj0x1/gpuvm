<#
.SYNOPSIS
    Lab 059: drag along paths (input.act `drag` with `strokes`, guest agent 0.4.7). Opens Paint on an agent machine,
    draws a circle and a spiral (one call, two strokes), a star of 5 lines + a wave + 3 dots (one call, 9 strokes) and
    a 500-point spiral at three speeds, times each call and saves the picture.

.DESCRIPTION
    Talks to the guest agent directly (Invoke-GpuVMAgent through the GpuVM service; elevated PowerShell), so it needs
    agent 0.4.7 in the machine but not the new MCP server. Run it in two steps:
      1. .\run.ps1 -Name <machine>                 opens Paint maximized and saves out\before.png (full desktop pixels)
      2. .\run.ps1 -Name <machine> -Canvas x,y,w,h  the white canvas's box read from before.png; draws, saves out\paint.png
    -CancelTest adds a 10 s spiral that Suspend-GpuVMAgent -Reason control stops after 2 s (then Resume-GpuVMAgent).
    Nothing else of the machine is touched; Paint stays open (close it without saving).
#>
param(
    [Parameter(Mandatory)][string]$Name,
    [int[]]$Canvas,
    [switch]$CancelTest,
    [string]$Out = (Join-Path $PSScriptRoot 'out')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM') -Force
New-Item -ItemType Directory -Force $Out | Out-Null

function Invoke-Agent([string]$method, $params, [int]$timeout = 60) {
    $r = Invoke-GpuVMAgent -Name $Name -Method $method -Params $params -TimeoutSec $timeout
    if (-not $r.ok) { throw "$method failed: $($r.error | ConvertTo-Json -Compress)" }
    $r
}
function Save-Screen([string]$file) {
    $r = Invoke-Agent screen.capture @{ maxW = 7680; maxH = 4320; format = 'png' }
    Copy-Item -LiteralPath $r.blobPath -Destination (Join-Path $Out $file) -Force
    Write-Host "saved out\$file ($($r.result.w)x$($r.result.h))"
}

if (-not $Canvas) {
    $info = Invoke-Agent agent.info @{}
    if ([version]($info.result.version -replace '[^\d.].*$') -lt [version]'0.4.7') { throw "The machine runs agent $($info.result.version); this lab needs 0.4.7." }
    $null = Invoke-Agent exec.run @{ file = 'powershell.exe'; args = @('-NoProfile', '-Command', 'Start-Process mspaint -WindowStyle Maximized') }
    Start-Sleep 4
    Save-Screen 'before.png'
    Write-Host 'Read the white canvas box from out\before.png and run again with -Canvas x,y,w,h.'
    return
}
if ($Canvas.Count -ne 4) { throw '-Canvas is x,y,w,h in desktop pixels.' }
$cx0, $cy0, $cw, $ch = $Canvas

# A path as a flat [x0, y0, x1, y1, ...] list of desktop pixels (what the agent takes).
function Flat($pts) { , [int[]]@($pts | ForEach-Object { [math]::Round($_[0]); [math]::Round($_[1]) }) }
function Circle($cx, $cy, $r, $n) { Flat @(0..$n | ForEach-Object { $a = 2 * [math]::PI * $_ / $n; , @(($cx + $r * [math]::Cos($a)), ($cy + $r * [math]::Sin($a))) }) }
function Spiral($cx, $cy, $r, $turns, $n) { Flat @(0..($n - 1) | ForEach-Object { $t = $_ / ($n - 1); $a = 2 * [math]::PI * $turns * $t; , @(($cx + $r * $t * [math]::Cos($a)), ($cy + $r * $t * [math]::Sin($a))) }) }

$results = [Collections.Generic.List[object]]::new()
function Drag([string]$label, [object[]]$strokes, $ms) {
    $action = @{ type = 'drag'; strokes = $strokes }
    if ($null -ne $ms) { $action.ms = $ms }
    $points = ($strokes | ForEach-Object { $_.Count / 2 } | Measure-Object -Sum).Sum
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-GpuVMAgent -Name $Name -Method input.act -Params @{ actions = @($action); stopOnError = $true } -TimeoutSec 120
    $row = [pscustomobject]@{ label = $label; strokes = $strokes.Count; points = $points; ms = $ms; ok = $r.ok; agentMs = $r.ms
        wallMs = $sw.ElapsedMilliseconds; msPerPoint = [math]::Round($r.ms / $points, 2); error = ($r.error | ConvertTo-Json -Compress) }
    $results.Add($row)
    Write-Host ("{0}: ok={1} {2} pts in {3} ms ({4} ms/pt) {5}" -f $label, $row.ok, $points, $row.agentMs, $row.msPerPoint, $row.error)
}

$cy = $cy0 + $ch * 0.55
$cell = [math]::Min($cw / 4, $ch) * 0.4
$x = 0.125, 0.375, 0.625, 0.875 | ForEach-Object { $cx0 + $cw * $_ }

# 1. A circle (361 points) and a spiral (500 points): one call, two strokes, default speed (1500 px/s).
Drag 'circle+spiral, default speed' @((Circle $x[0] $cy $cell 360), (Spiral $x[1] $cy $cell 4 500)) $null
# 2. Separate strokes in one call: a star as 5 lines, a wave and 3 dots (9 strokes).
$tip = { param($i) $a = -[math]::PI / 2 + 4 * [math]::PI * $i / 5; @(($x[2] + $cell * [math]::Cos($a)), ($cy + $cell * [math]::Sin($a))) }
$star = @(0..4 | ForEach-Object { Flat @((& $tip $_), (& $tip ($_ + 1))) })
$wave = Flat @(0..80 | ForEach-Object { , @(($x[3] - $cell + 2 * $cell * $_ / 80), ($cy - $cell / 2 + $cell / 3 * [math]::Sin($_ / 8))) })
$dots = @(0..2 | ForEach-Object { , [int[]]@(($x[3] - $cell / 2 + $cell / 2 * $_), ($cy + $cell * 0.6)) })
Drag 'star lines+wave+dots' (@($star) + @(, $wave) + $dots) $null
# 3. Timing: a 500-point spiral at 2000 ms, 500 ms (1 ms a point) and 100 ms (faster than Paint reads moves).
$i = 0
foreach ($ms in 2000, 500, 100) {
    Drag "spiral 500 pts, $ms ms" @(, (Spiral ($x[0] + $cell * (1.2 + 1.1 * $i)) ($cy0 + $ch * 0.16) ($cell * 0.3) 3 500)) $ms
    $i++
}
# 4. Optional: the person takes control 2 s into a 10 s spiral; the call must end at ~2 s with the button released.
if ($CancelTest) {
    $job = Start-ThreadJob -ArgumentList $Name { param($n) Start-Sleep 2; Import-Module (Join-Path $using:PSScriptRoot '..\..\src\GpuVM') -Force
        Suspend-GpuVMAgent -Name $n -Reason control -Message 'lab 059 cancel test' }
    Drag 'spiral 10 s, control taken at 2 s' @(, (Spiral ($x[3]) ($cy0 + $ch * 0.16) ($cell * 0.3) 6 1500)) 10000
    Receive-Job $job -Wait -AutoRemoveJob | Out-Null
    Resume-GpuVMAgent -Name $Name | Out-Null
}
Save-Screen 'paint.png'
$results | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Out 'results.json') -Encoding utf8
$results | Format-Table label, strokes, points, ms, ok, agentMs, wallMs, msPerPoint -AutoSize | Out-String | Write-Host
