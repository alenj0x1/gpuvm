# Lab 057: black flashes in a machine's stream, measured without anyone at the PC. Optionally puts a WGC helper
# build in the guest (swap-helper.ps1), shows an animated clock in the guest's session, opens GpuVM's viewer the way
# the labs do (its own pipe), records -Seconds of the stream through the viewer ("record" over the pipe, as the app
# does), and counts the frames that turn half-composed (glitches.py). Closes any open viewer first. Run elevated.
# Out: out\flashes-<label>.json
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Label,
    [string]$Helper,
    [int]$Seconds = 60,
    [ValidateSet('label', 'labelvideo', 'clock', 'browser')][string]$Load = 'label'
)
# -Load label: the first clock of this lab, a WinForms label and background changed every 16 ms (repainted whole,
# not double buffered). It is the load that shows the flashes (58 a minute on 2026-11-21 12:46); the double-buffered
# clock and the browser animation barely do (3-6 and 0 a minute with the same helper).
$labelTicker = @'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$f = New-Object Windows.Forms.Form
$f.Text = 'lab057 ticker'; $f.WindowState = 'Maximized'; $f.TopMost = $true; $f.BackColor = 'White'
$l = New-Object Windows.Forms.Label
$l.Dock = 'Fill'; $l.TextAlign = 'MiddleCenter'; $l.Font = New-Object Drawing.Font('Consolas', 110)
$f.Controls.Add($l)
$t = New-Object Windows.Forms.Timer; $t.Interval = 16
$t.Add_Tick({ $l.Text = (Get-Date).ToString('HH:mm:ss.ff'); $f.BackColor = [Drawing.Color]::FromArgb(255, 255, 200 + (Get-Date).Millisecond % 55) })
$t.Start(); [void]$f.ShowDialog()
'@
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null
if ($Helper) { & (Join-Path $PSScriptRoot 'swap-helper.ps1') -Name $Name -Helper $Helper | Out-Null }
Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
. (Join-Path $root 'tools\latency\common.ps1')
$m = Get-Module GpuVM
$state = & $m { param($n) Get-GpuVMState -Name $n } $Name
$cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state

# The clock: a maximized window redrawn every 16 ms in the signed-in user's session (a task, as that user).
$ticker = @'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$f = New-Object Windows.Forms.Form
$f.Text = 'lab057 ticker'; $f.WindowState = 'Maximized'; $f.TopMost = $true; $f.BackColor = 'White'
# Double buffered, painted by hand every 16 ms: big clock, a bar sweeping across, and moving blocks.
$f.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($f, $true)
$font = New-Object Drawing.Font('Consolas', 110)
$script:n = 0
$f.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $w = $s.ClientSize.Width; $h = $s.ClientSize.Height; $script:n++
    $g.Clear([Drawing.Color]::FromArgb(255, 255, 200 + $script:n % 55))
    $x = ($script:n * 12) % $w
    $g.FillRectangle([Drawing.Brushes]::SteelBlue, $x, 0, 60, $h)
    for ($i = 0; $i -lt 12; $i++) { $g.FillRectangle([Drawing.Brushes]::IndianRed, ($script:n * (3 + $i) + $i * 150) % $w, ($i * 83) % $h, 80, 40) }
    $g.DrawString((Get-Date).ToString('HH:mm:ss.ff'), $font, [Drawing.Brushes]::Black, $w / 2 - 520, $h / 2 - 90)
})
$t = New-Object Windows.Forms.Timer; $t.Interval = 16
$t.Add_Tick({ $f.Invalidate() })
$t.Start(); [void]$f.ShowDialog()
'@
# -Load browser: a canvas animation in Firefox's kiosk mode, drawn on every vsync of the virtual display (180 Hz),
# like the YouTube video of the session where the flashes were seen (the clock above draws ~30 changes a second and
# barely shows them).
$page = @'
<!doctype html><html><body style="margin:0;overflow:hidden;background:#fff"><canvas id="c"></canvas><script>
const c = document.getElementById('c'), g = c.getContext('2d'); let n = 0;
function f(t) { c.width = innerWidth; c.height = innerHeight; n++;
  g.fillStyle = `hsl(${n % 360},60%,85%)`; g.fillRect(0, 0, c.width, c.height);
  for (let i = 0; i < 40; i++) { g.fillStyle = `hsl(${(i * 37 + n * 3) % 360},70%,50%)`;
    g.fillRect((n * (2 + i % 7) + i * 97) % c.width, (i * 53 + n * (i % 3)) % c.height, 120, 70); }
  g.fillStyle = '#000'; g.font = '120px Consolas'; g.fillText(new Date().toISOString().slice(11, 23), c.width / 2 - 450, c.height / 2);
  requestAnimationFrame(f); }
requestAnimationFrame(f);
</script></body></html>
'@
# -Load labelvideo: the label clock (not maximized, on top) over Firefox playing an H.264 video in a loop, like the
# session where Firefox played a YouTube video the whole time (the flashes fell from ~58 to ~7 a minute once that
# Firefox was closed).
$videoPage = '<!doctype html><html><body style="margin:0;background:#000"><video src="lab057-video.mp4" autoplay loop muted style="width:100vw;height:100vh"></video></body></html>'
if ($Load -in 'label', 'labelvideo') { $ticker = $labelTicker }
if ($Load -eq 'labelvideo') {
    $ticker = $ticker.Replace("`$f.WindowState = 'Maximized'", "`$f.StartPosition = 'Manual'; `$f.Location = New-Object Drawing.Point(0, 0); `$f.Size = New-Object Drawing.Size(1100, 700)")
    $video = Join-Path $PSScriptRoot 'out\lab057-video.mp4'
    if (-not (Test-Path $video)) {
        & ffmpeg -v error -f lavfi -i 'testsrc2=size=1280x720:rate=60' -t 20 -c:v libx264 -pix_fmt yuv420p -preset veryfast -b:v 6M $video -y
    }
    $vs = New-PSSession -VMName $Name -Credential $cred
    Copy-Item -ToSession $vs -Path $video -Destination 'C:\Users\Public\lab057-video.mp4' -Force
    Remove-PSSession $vs
}
Invoke-Command -VMName $Name -Credential $cred -ArgumentList $ticker, $page, $Load, $videoPage {
    param($ticker, $page, $load, $videoPage)
    Set-Content C:\Users\Public\lab057-ticker.ps1 $ticker
    Set-Content C:\Users\Public\lab057.html $page
    Set-Content C:\Users\Public\lab057-video.html $videoPage
    $user = (Get-CimInstance Win32_ComputerSystem).UserName -replace '^.*\\'
    $firefox = "C:\Users\$user\AppData\Local\Mozilla Firefox\firefox.exe"
    # A running Firefox would take the page as a tab behind other windows instead of a kiosk on top.
    if ($load -in 'browser', 'labelvideo') { Get-Process firefox -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2 }
    # Windows won't let a task's window take the foreground: everything else is minimized first.
    $open = if ($load -eq 'labelvideo') { "'--new-window file:///C:/Users/Public/lab057-video.html'; Start-Sleep 4; Start-Process powershell.exe '-ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Users\Public\lab057-ticker.ps1'" }
    else { "'--kiosk --new-window file:///C:/Users/Public/lab057.html'" }
    Set-Content C:\Users\Public\lab057-browser.ps1 "(New-Object -ComObject Shell.Application).MinimizeAll(); Start-Sleep 1; Start-Process '$firefox' $open"
    $a = if ($load -in 'browser', 'labelvideo') { New-ScheduledTaskAction -Execute powershell.exe -Argument '-ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Users\Public\lab057-browser.ps1' }
    else { New-ScheduledTaskAction -Execute powershell.exe -Argument '-ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Users\Public\lab057-ticker.ps1' }
    Register-ScheduledTask -TaskName lab057ticker -Action $a -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive) -Force | Out-Null
    Start-ScheduledTask lab057ticker
} | Out-Null

$row = [ordered]@{ label = $Label; at = (Get-Date).ToString('s'); seconds = $Seconds }
$session = $null
try {
    $launch = (Connect-GpuVM -Name $Name -Viewer 6>$null).viewerLaunch
    $started = Get-Date
    $session = Start-LatencyViewer -Viewer gpuvm -Arguments @($launch.arguments)
    $row.firstFrameSec = Wait-LatencyViewerFrame $session -Since $started
    if ($row.firstFrameSec -lt 0) { throw "no picture: $(@($session.Bridge.Events.ToArray()) -join ' ')" }
    Start-Sleep -Seconds 3
    $events = { param($type) @($session.Bridge.Events.ToArray() | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_.type -eq $type }) }
    [void]$session.Bridge.Send((@{ type = 'capture-setup'; replay = $false; seconds = 30; lang = 'es' } | ConvertTo-Json -Compress))
    [void]$session.Bridge.Send('{"type":"record","on":true}')
    $w = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $events 'recording') -and $w.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 200 }
    if (-not (& $events 'recording')) { throw "the viewer didn't start recording: $(@($session.Bridge.Events.ToArray()) -join ' ')" }
    Start-Sleep -Seconds $Seconds
    [void]$session.Bridge.Send('{"type":"record","on":false}')
    $w.Restart()
    while (-not ($file = & $events 'capture' | Select-Object -Last 1) -and $w.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 300 }
    if (-not $file) { throw 'the viewer saved no recording' }
    $path = Join-Path $env:USERPROFILE "AppData\LocalLow\GpuVM\Viewer\Captures\$($file.file)"
    if (-not (Test-Path $path)) { $path = $file.file }
    $row.file = $path
    $row.stats = Get-LatencyViewerStats $session -LastSeconds $Seconds
    $count = & python -I (Join-Path $PSScriptRoot 'glitches.py') $path
    $row.glitches = $count
    if (($count | Select-Object -First 1) -match 'moving_fps=([\d.]+) .* glitches=(\d+) per_min=([\d.]+)') { $row.movingFps = [double]$Matches[1]; $row.count = [int]$Matches[2]; $row.perMin = [double]$Matches[3] }
}
catch { $row.error = "$_" }
finally {
    if ($session) { Stop-Process -Id $session.Process.Id -Force -ErrorAction SilentlyContinue; if ($session.Bridge) { $session.Bridge.Dispose() } }
    $row.helper = Invoke-Command -VMName $Name -Credential $cred {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object CommandLine -match 'lab057-ticker' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
        if ($using:Load -in 'browser', 'labelvideo') { Get-Process firefox -ErrorAction SilentlyContinue | Stop-Process -Force }
        Unregister-ScheduledTask lab057ticker -Confirm:$false -ErrorAction SilentlyContinue
        $user = (Get-CimInstance Win32_ComputerSystem).UserName -replace '^.*\\'
        $f = Get-ChildItem "C:\Users\$user\AppData\Roaming\Sunshine\wgc-helper" -Filter *.log | Sort-Object Name | Select-Object -Last 1
        [ordered]@{
            hash  = (Get-FileHash 'C:\Program Files\Sunshine\tools\sunshine_wgc_capture.exe').Hash.Substring(0, 12)
            lines = @(Get-Content $f.FullName | Where-Object { $_ -match 'capture_fps|GpuVM' } | Select-Object -Last 12)
        }
    }
    $row | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out "flashes-$Label.json")
}
[pscustomobject]$row | Select-Object label, firstFrameSec, movingFps, count, perMin, error, file
