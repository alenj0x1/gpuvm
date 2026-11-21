# Lab 063: runs the WGC race probe (probe\wgc-race.exe) inside a machine, as its signed-in user, while a load moves
# the screen, and brings back its result.json and the first frames that changed after Windows handed them over.
# Doesn't touch the viewer or Sunshine. Run elevated. Out: out\<Label>\result.json (+ evN-a/b/mask.png)
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Label,
    [int]$Seconds = 60,
    [string]$Delays = '0',
    [int]$HoldMs = 20,
    [int]$Pool = 3,
    [int]$Save = 6,
    [ValidateSet('none', 'high', 'rt')][string]$Prio = 'none',
    # fast2 only: variants used in turn, frame by frame ("0,fix,1000"): µs to spin before the copy, or "fix" (check for
    # transparent blocks and copy again once Windows finished the frame)
    [string]$DelayUs = '0',
    # fast2 only: a game-like GPU load next to the capture (copies per batch of 4096x4096 textures; 0 = none)
    [int]$GpuLoad = 0,
    # fast2 only: threads spinning at normal priority in the probe (CPU load, like a game)
    [int]$CpuLoad = 0,
    # fast2 "fix" variant: how long it keeps checking a frame before giving up (ms)
    [int]$FixBudgetMs = 10,
    # fast2 only: Windows draws the cursor into the frames (the helper does when the cursor is shown)
    [switch]$Cursor,
    # start the probe 3 s before the load, so it sees the windows opening (where the helper got most bad frames)
    [switch]$ProbeFirst,
    [ValidateSet('none', 'label', 'video', 'labelvideo', 'churn', 'videochurn')][string]$Load = 'labelvideo',
    [string]$Probe = (Join-Path $PSScriptRoot 'probe\target\release\wgc-race.exe')
)
. (Join-Path $PSScriptRoot 'common.ps1')
$cred = Get-Lab063Cred $Name
$out = Join-Path $PSScriptRoot "out\$Label"
New-Item -ItemType Directory -Force $out | Out-Null
$video = Join-Path $PSScriptRoot '..\057-capture-broker\out\lab057-video.mp4'
if (-not (Test-Path $video)) {
    & ffmpeg -v error -f lavfi -i 'testsrc2=size=1280x720:rate=60' -t 20 -c:v libx264 -pix_fmt yuv420p -preset veryfast -b:v 6M $video -y
}
# The label clock of lab 057: a WinForms label and background repainted whole every 16 ms (not double buffered).
$ticker = @'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$f = New-Object Windows.Forms.Form
$f.Text = 'lab063 ticker'; $f.TopMost = $true; $f.BackColor = 'White'
if ($args[0] -eq 'small') { $f.StartPosition = 'Manual'; $f.Location = New-Object Drawing.Point(0, 0); $f.Size = New-Object Drawing.Size(1100, 700) } else { $f.WindowState = 'Maximized' }
$l = New-Object Windows.Forms.Label
$l.Dock = 'Fill'; $l.TextAlign = 'MiddleCenter'; $l.Font = New-Object Drawing.Font('Consolas', 110)
$f.Controls.Add($l)
$t = New-Object Windows.Forms.Timer; $t.Interval = 16
$t.Add_Tick({ $l.Text = (Get-Date).ToString('HH:mm:ss.ff'); $f.BackColor = [Drawing.Color]::FromArgb(255, 255, 200 + (Get-Date).Millisecond % 55) })
$t.Start(); [void]$f.ShowDialog()
'@
$page = '<!doctype html><html><body style="margin:0;background:#000"><video src="video.mp4" autoplay loop muted style="width:100vw;height:100vh"></video></body></html>'
# -Load churn / videochurn: windows opening and closing all the time (a new one every 150 ms at a random place, at
# most 6 open): where the helper got most of its half-drawn frames (Edge, Paint and the clock appearing).
$churn = @'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$rnd = New-Object Random
$open = New-Object System.Collections.Queue
$main = New-Object Windows.Forms.Form
$main.Text = 'lab063 churn'; $main.ShowInTaskbar = $false; $main.Size = New-Object Drawing.Size(1, 1); $main.Opacity = 0
$t = New-Object Windows.Forms.Timer; $t.Interval = 150
$t.Add_Tick({
    $w = New-Object Windows.Forms.Form
    $w.Text = 'lab063 churn window'; $w.TopMost = $true; $w.ShowInTaskbar = $false; $w.StartPosition = 'Manual'
    $w.Location = New-Object Drawing.Point($rnd.Next(0, 1400), $rnd.Next(0, 650))
    $w.Size = New-Object Drawing.Size($rnd.Next(250, 600), $rnd.Next(180, 420))
    $w.BackColor = [Drawing.Color]::FromArgb(255, $rnd.Next(80, 256), $rnd.Next(80, 256), $rnd.Next(80, 256))
    $w.Show()
    $open.Enqueue($w)
    if ($open.Count -gt 6) { $open.Dequeue().Close() }
})
$t.Start(); [void]$main.ShowDialog()
'@

$s = New-PSSession -VMName $Name -Credential $cred
$row = [ordered]@{ label = $Label; at = (Get-Date).ToString('s'); load = $Load; prio = $Prio; seconds = $Seconds; delays = $Delays; holdMs = $HoldMs; pool = $Pool }
try {
    Invoke-Command -Session $s { Remove-Item C:\Users\Public\lab063 -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force C:\Users\Public\lab063 | Out-Null }
    Copy-Item -ToSession $s -Path $Probe -Destination 'C:\Users\Public\lab063\wgc-race.exe' -Force
    if ($Load -in 'video', 'labelvideo', 'videochurn') { Copy-Item -ToSession $s -Path $video -Destination 'C:\Users\Public\lab063\video.mp4' -Force }
    $row.cursor = $Cursor.IsPresent
    $row.probeFirst = $ProbeFirst.IsPresent
    $row.guest = Invoke-Command -Session $s -ArgumentList @($ticker, $page, $Load, $Seconds, $Delays, $HoldMs, $Pool, $Save, $Prio, $DelayUs, $(if ($Cursor) { 'cursor' } else { 'nocursor' }), $ProbeFirst.IsPresent, $churn, $GpuLoad, $CpuLoad, $FixBudgetMs) {
        param($ticker, $page, $load, $seconds, $delays, $hold, $pool, $save, $prio, $delayUs, $cursor, $probeFirst, $churn, $gpuLoad, $cpuLoad, $fixBudget)
        $dir = 'C:\Users\Public\lab063'
        Set-Content "$dir\ticker.ps1" $ticker
        Set-Content "$dir\churn.ps1" $churn
        Set-Content "$dir\video.html" $page
        $user = (Get-CimInstance Win32_ComputerSystem).UserName.Split('\')[-1]
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
        $edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
        $lines = @()
        if ($load -in 'churn', 'videochurn') { $lines += "Start-Process powershell.exe '-ExecutionPolicy Bypass -WindowStyle Hidden -File $dir\churn.ps1'" }
        if ($load -in 'video', 'labelvideo', 'videochurn') { $lines += "Start-Process '$edge' '--no-first-run --kiosk --edge-kiosk-type=fullscreen --autoplay-policy=no-user-gesture-required --user-data-dir=$dir\edge file:///C:/Users/Public/lab063/video.html'; Start-Sleep 4" }
        if ($load -eq 'label') { $lines += "Start-Process powershell.exe '-ExecutionPolicy Bypass -WindowStyle Hidden -File $dir\ticker.ps1 big'" }
        if ($load -eq 'labelvideo') { $lines += "Start-Process powershell.exe '-ExecutionPolicy Bypass -WindowStyle Hidden -File $dir\ticker.ps1 small'" }
        $startLoad = {
            if ($lines) {
                Set-Content "$dir\load.ps1" ($lines -join "`r`n")
                $a = New-ScheduledTaskAction -Execute powershell.exe -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File $dir\load.ps1"
                Register-ScheduledTask -TaskName lab063load -Action $a -Principal $principal -Force | Out-Null
                Start-ScheduledTask lab063load
            }
        }
        if (-not $probeFirst) { & $startLoad; if ($lines) { Start-Sleep 8 } }
        $a = New-ScheduledTaskAction -Execute "$dir\wgc-race.exe" -Argument "$seconds $dir\out $delays $hold $pool $save $prio $delayUs $cursor $gpuLoad $cpuLoad $fixBudget"
        Register-ScheduledTask -TaskName lab063probe -Action $a -Principal $principal -Force | Out-Null
        Start-ScheduledTask lab063probe
        if ($probeFirst) { Start-Sleep 3; & $startLoad }
        $w = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path "$dir\out\result.json") -and $w.Elapsed.TotalSeconds -lt $seconds + 90) { Start-Sleep 1 }
        Start-Sleep 1
        [ordered]@{ user = $user; waitedSec = [int]$w.Elapsed.TotalSeconds; done = (Test-Path "$dir\out\result.json") }
    }
    if ($row.guest.done) {
        # Collected first: copying while the listing still streams over the same session fails with "Busy".
        $names = @(Invoke-Command -Session $s { Get-ChildItem C:\Users\Public\lab063\out -File | ForEach-Object Name })
        foreach ($n in $names) { Copy-Item -FromSession $s -Path "C:\Users\Public\lab063\out\$n" -Destination $out -Force }
    }
}
catch { $row.error = "$_" }
finally {
    Invoke-Command -Session $s {
        Stop-ScheduledTask lab063probe -ErrorAction SilentlyContinue
        Get-Process wgc-race -ErrorAction SilentlyContinue | Stop-Process -Force
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object CommandLine -match 'lab063' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object CommandLine -match 'lab063' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Unregister-ScheduledTask lab063load -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-ScheduledTask lab063probe -Confirm:$false -ErrorAction SilentlyContinue
    }
    Remove-PSSession $s
    $row | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $out 'run.json')
}
$r = Get-Content (Join-Path $out 'result.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
if ($r.error) { "probe error: $($r.error)" }
if ($row.error) { "run error: $($row.error)" }
if ($r.mode -eq 'fast2') {
    "$Label  fast2: captured=$($r.captured) ($($r.capturedFps)/s) analysed=$($r.analysed) skipped=$($r.skipped) gaps=$($r.gaps) moving=$($r.movingPct)% pool=$($r.pool) delayUs=$($r.delayUs) prio=$($r.prio | ConvertTo-Json -Compress) cursor=$($r.cursor) copyWait avg/max=$($r.copyWaitUs.avg)/$($r.copyWaitUs.max) us | glitches=$($r.glitches) ($($r.glitchesPerMin)/min) | alpha0 frames=$($r.alpha0Frames) px=$($r.alpha0Px)"
    if ($r.gpuLoad.batch) { "  gpu load: batch $($r.gpuLoad.batch), $($r.gpuLoad.batches) batches" }
    if ($r.fixEvents) { "  fix events (ms until complete, * = gave up after $($r.fixBudgetMs) ms): " + (($r.fixEvents | ForEach-Object { '{0:N1}{1}' -f ($_.us / 1000), $(if ($_.gaveUp) { '*' } else { '' }) }) -join ' ') }
    $r.variants | ForEach-Object { "  variant {0,-5}: frames {1}, alpha0 {2}, glitches {3} | fixed {4} (retries {5}, extra avg/max {6}/{7} us, gave up {8})" -f $_.variant, $_.frames, $_.alpha0Frames, $_.glitches, $_.fixed, $_.retries, $_.extraUsAvg, $_.extraUsMax, $_.exhausted }
}
if ($r.mode -eq 'fast') {
    "$Label  fast: processed=$($r.processed) ($($r.processedFps)/s) arrived=$($r.arrived) drained=$($r.drained) moving=$($r.movingPct)% pool=$($r.pool) prio=$($r.prio | ConvertTo-Json -Compress) copyWait avg/max=$($r.copyWaitUs.avg)/$($r.copyWaitUs.max) us | A2 changed=$($r.a2Changed) | glitches=$($r.glitches) ($($r.glitchesPerMin)/min)"
    $r.glitchFrames | Select-Object -First 8 | ForEach-Object { "  glitch t=$($_.t) cells=$($_.cells) a2DiffPx=$($_.a2DiffPx) saved=$($_.saved)" }
}
if ($r.buckets) {
    "$Label  arrived=$($r.arrived) processed=$($r.processed) moving=$($r.movingPct)% lateHold=$($r.lateHold) prio=$($r.prio | ConvertTo-Json -Compress) adapter=$($r.adapter) size=$($r.size -join 'x')"
    $r.buckets | ForEach-Object { "  delay {0,5} us: {1}/{2} changed ({3}%), glitches {13}, black frames {4}, mean px {5}, max px {6}, alpha 0/255/other {7}/{8}/{9}, ageA p50 {10} us, copyA p50/p95 {11}/{12} us" -f $_.delayUs, $_.changed, $_.samples, $_.changedPct, $_.blackFrames, $_.meanPx, $_.maxPx, $_.alphaOfChangedInA.'0', $_.alphaOfChangedInA.'255', $_.alphaOfChangedInA.other, $_.ageAUs.p50, $_.copyAUs.p50, $_.copyAUs.p95, $_.glitches }
}
