# Lab 063: GPU drawing on the PC (like GpuVM's own animated home page, which made the unfinished frames 10x more
# common): host-load.html in a headless Edge, nothing on screen. -Stop ends it (its whole tree, by the marker in its
# command line). Prints the PC's GPU use a few seconds in.
param([int]$Iters = 60, [int]$Width = 2560, [int]$Height = 1440, [switch]$Stop, [switch]$Unlimited, [switch]$Visible)
$marker = 'gpuvm-lab063-hostload'
$profile = Join-Path $env:TEMP $marker
function Stop-HostLoad {
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -match $marker } |
        ForEach-Object { & taskkill /T /F /PID $_.ProcessId 2>$null | Out-Null }
}
Stop-HostLoad
if ($Stop) { return 'host load stopped' }
$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
$page = 'file:///' + ((Join-Path $PSScriptRoot 'host-load.html') -replace '\\', '/') + "?iters=$Iters"
# -Unlimited draws as fast as it can (~100 % of the GPU); otherwise at the display's rate, like an app.
# -Visible: an app window on the second monitor (x = -1920) instead of headless. Drawing that the PC shows on a display
# is what made the unfinished frames common (GpuVM's animated home page); headless drawing at the same load barely did.
$flags = @('--no-first-run', "--user-data-dir=$profile", "--window-size=$Width,$Height", '--use-angle=d3d11', '--ignore-gpu-blocklist')
if ($Visible) { $flags += '--window-position=-1920,0'; $page = "--app=$page" } else { $flags = @('--headless=new') + $flags }
if ($Unlimited) { $flags += '--disable-frame-rate-limit' }
Start-Process $edge -ArgumentList ($flags + $page) -WindowStyle Hidden | Out-Null
Start-Sleep 6
$pct = (nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | Select-Object -First 1)
"host load running (iters $Iters, ${Width}x$Height): GPU $pct %"
