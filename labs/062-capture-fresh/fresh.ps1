# Lab 062: does a screen.capture taken right after an input.act show that action? Run elevated, with classic Paint
# maximized in front on a 1920x1080 machine (pencil or brush selected), nobody else using it.
#   .\fresh.ps1 -Name an agent machine                          (the agent's default settleMs)
#   .\fresh.ps1 -Name an agent machine -Settle 0,10,20,30 -Row 0   (compare settleMs values, agent 0.4.9+)
#   .\fresh.ps1 -From out\<time>\settle-20 -Row 2               (analyze saved pictures again)
# Per round: capture A, drag a short new stroke, capture B at once, wait 600 ms, capture C.
# Fresh = inside the stroke's rectangle, B differs from A (the stroke is there) and matches C (all of it). Only that
# rectangle counts: Paint's status bar (cursor position) and the taskbar change on their own.
# Strokes are 40x15 px on a grid in the canvas' bottom strip: column = round (10), row = one per settleMs value
# (-Row = the first row; 6 rows fit, y 665-770), so each stroke is new pixels without clearing the canvas.
# Also times capture alone on a still screen (grab = the agent's own time to get the frame).
param([string]$Name, [int]$Rounds = 10, [int]$Alone = 5, [string]$From, [int[]]$Settle, [int]$Row = 0)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function Get-Rect([int]$i, [int]$row) { $x0 = 20 + 110 * ($i - 1); $y0 = 665 + 18 * $row; @{ x = $x0; y = $y0; toX = $x0 + 40; toY = $y0 + 15 } }

# changed pixels between two PNGs inside the stroke's rectangle (+4 px), any channel differing by > 24
function Get-Diff([string]$a, [string]$b, $r) {
    $x = [Drawing.Bitmap]::new($a); $y = [Drawing.Bitmap]::new($b)
    try {
        $rect = [Drawing.Rectangle]::new($r.x - 4, $r.y - 2, $r.toX - $r.x + 8, $r.toY - $r.y + 4)
        $dx = $x.LockBits($rect, 'ReadOnly', 'Format32bppArgb'); $dy = $y.LockBits($rect, 'ReadOnly', 'Format32bppArgb')
        $n = $dx.Stride * $rect.Height
        $bx = [byte[]]::new($n); $by = [byte[]]::new($n)
        [Runtime.InteropServices.Marshal]::Copy($dx.Scan0, $bx, 0, $n); [Runtime.InteropServices.Marshal]::Copy($dy.Scan0, $by, 0, $n)
        $x.UnlockBits($dx); $y.UnlockBits($dy)
        $c = 0
        for ($i = 0; $i -lt $n; $i += 4) {
            if ([Math]::Abs($bx[$i] - $by[$i]) -gt 24 -or [Math]::Abs($bx[$i + 1] - $by[$i + 1]) -gt 24 -or [Math]::Abs($bx[$i + 2] - $by[$i + 2]) -gt 24) { $c++ }
        }
        $c
    } finally { $x.Dispose(); $y.Dispose() }
}

function Get-Row([string]$dir, [int]$i, [int]$row, $ms, $grab) {
    $r = Get-Rect $i $row
    $ab = Get-Diff "$dir\r$i-a.png" "$dir\r$i-b.png" $r
    $bc = Get-Diff "$dir\r$i-b.png" "$dir\r$i-c.png" $r
    [pscustomobject]@{ round = $i; roundTripMs = $ms; grabMs = $grab; strokeInB = $ab; missingFromB = $bc; fresh = ($ab -ge 20 -and $bc -le 2) }
}

if ($From) {
    $dir = (Resolve-Path $From).Path
    $rows = foreach ($i in 1..$Rounds) { if (Test-Path "$dir\r$i-a.png") { Get-Row $dir $i $Row $null $null } }
    $rows | Format-Table -AutoSize | Out-String
    "fresh: $(@($rows | Where-Object fresh).Count) / $(@($rows).Count)"
    return
}
if (-not $Name) { throw '-Name or -From' }
Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
$fg = (Invoke-GpuVMAgent -Name $Name -Method screen.state).result.foreground
if ($fg.process -ne 'mspaint.exe') { throw "Paint must be in front (now: $($fg.process) '$($fg.title)')" }
$out = Join-Path $PSScriptRoot "out\$(Get-Date -Format yyyyMMdd-HHmmss)"
New-Item -ItemType Directory -Force $out | Out-Null

function Get-Shot([string]$dir, [string]$tag, $settle) {
    $p = @{ format = 'png'; maxW = 3840; maxH = 2160 }
    if ($null -ne $settle) { $p.settleMs = $settle }
    $r = Invoke-GpuVMAgent -Name $Name -Method screen.capture -Params $p
    if (-not $r.ok) { throw "capture: $($r.error | ConvertTo-Json -Compress)" }
    Copy-Item $r.blobPath (Join-Path $dir "$tag.png")
    [pscustomobject]@{ ms = $r.ms; grab = $r.result.ms.grab; frames = $r.result.settleFrames }
}

function Get-Median($v) { $s = @($v | Sort-Object); "median $($s[[int][Math]::Floor($s.Count / 2)]) min $($s[0]) max $($s[-1])" }

$agentVersion = (Invoke-GpuVMAgent -Name $Name -Method exec.run -Params @{ file = 'C:\Program Files\GpuVM Agent\gpuvm-agent.exe'; args = @('version') }).result.stdout.Trim()
"agent: $agentVersion"
$row = $Row
# -1 = the agent's default (no settleMs sent)
foreach ($v in $(if ($Settle) { $Settle } else { @(-1) })) {
    $s = if ($v -lt 0) { $null } else { $v }
    $dir = if ($null -eq $s) { $out } else { Join-Path $out "settle-$s" }
    New-Item -ItemType Directory -Force $dir | Out-Null
    "--- settleMs: $(if ($null -eq $s) { 'default' } else { $s })   (row $row)"
    $aloneShots = foreach ($i in 1..$Alone) { Get-Shot $dir "alone-$i" $s; Start-Sleep -Milliseconds 300 }
    "capture alone, round trip ms: $(Get-Median $aloneShots.ms)"
    "capture alone, grab ms:       $(Get-Median $aloneShots.grab)   frames while settling: $(Get-Median $aloneShots.frames)"
    $rows = foreach ($i in 1..$Rounds) {
        $null = Get-Shot $dir "r$i-a" $null
        $d = Invoke-GpuVMAgent -Name $Name -Method input.act -Params @{ actions = @(@{ type = 'drag' } + (Get-Rect $i $row)) }
        if (-not $d.ok) { throw "drag: $($d.error | ConvertTo-Json -Compress)" }
        $b = Get-Shot $dir "r$i-b" $s
        Start-Sleep -Milliseconds 600
        $null = Get-Shot $dir "r$i-c" $null
        Get-Row $dir $i $row $b.ms $b.grab
    }
    $rows | Format-Table -AutoSize | Out-String
    "fresh: $(@($rows | Where-Object fresh).Count) / $Rounds   (pictures: $dir)"
    $row++
}
