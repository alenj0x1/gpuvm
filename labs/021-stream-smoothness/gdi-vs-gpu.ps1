# Lab 021: is the slow picture of a stream the target's fault (GDI drawing in a GPU-P VM) or the stream's?
# Streams the VM with GpuVM's viewer (as the app does) and measures the same moving bar drawn two ways, in rounds:
#   gdi  tools/latency/motion-target.ps1 (GDI, full screen)
#   gpu  the same bar in Edge (an HTML page animated with requestAnimationFrame: composed on the GPU, like a game)
# Only reads the screen. Run elevated: pwsh -File labs/021-stream-smoothness/gdi-vs-gpu.ps1 -Name win-gpu
param(
    [Parameter(Mandatory)][string]$Name,
    [int]$Rounds = 2,
    [double]$Seconds = 15,
    [ValidateSet('moonlight', 'gpuvm')][string]$Viewer = 'gpuvm',
    # Measure even if the host GPU is busy (the load is recorded).
    [switch]$Force,
    [string]$Out = (Join-Path $PSScriptRoot "out\gdi-vs-gpu-$(Get-Date -Format 'yyyyMMdd-HHmmss').json")
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
$tools = Join-Path $PSScriptRoot '..\..\tools\latency'
. (Join-Path $tools 'common.ps1')
. (Join-Path $tools 'input-meter.ps1')
$hostGpuPct = Assert-LatencyGpuIdle -Force:$Force
"host GPU before: $hostGpuPct %" | Write-Host
. (Join-Path $tools 'motion-meter.ps1')

# One width every 2 s, from the page's high-resolution clock, as motion-target.ps1 does.
$html = @'
<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;height:100%;background:#000;overflow:hidden;cursor:none}
#bar{position:absolute;top:0;left:0;width:24px;height:100%;background:#fff;will-change:transform}
</style></head><body><div id="bar"></div><script>
const bar = document.getElementById('bar');
function tick(t) { const w = innerWidth - 24; bar.style.transform = 'translateX(' + ((t / 2000) % 1) * w + 'px)'; requestAnimationFrame(tick); }
requestAnimationFrame(tick);
</script></body></html>
'@

$vm = Get-LatencyVM -Name $Name
function Start-GuestTarget([string]$Kind) {
    Invoke-Command -VMName $Name -Credential $vm.Guest -ArgumentList $Kind, $html -ScriptBlock {
        param($kind, $html)
        Get-Process msedge -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -ne 0 } | Stop-Process -Force -ErrorAction SilentlyContinue
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object CommandLine -like '*latency-target.ps1*' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
        if ($kind -ne 'gpu') { return }
        New-Item -ItemType Directory -Force C:\GpuVM | Out-Null
        Set-Content C:\GpuVM\bar.html $html -Encoding utf8
        $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $edge) { throw 'Edge is not installed in the VM.' }
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        # A profile of its own: no first-run pages, no restore bubble.
        $arguments = "--kiosk file:///C:/GpuVM/bar.html --edge-kiosk-type=fullscreen --no-first-run --user-data-dir=C:\GpuVM\edge-bar"
        $action = New-ScheduledTaskAction -Execute $edge -Argument $arguments
        Register-ScheduledTask -TaskName GpuVM-BarTarget -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
        Start-ScheduledTask GpuVM-BarTarget; Start-Sleep -Seconds 4
        Unregister-ScheduledTask GpuVM-BarTarget -Confirm:$false
    }
    if ($Kind -eq 'gdi') { & (Join-Path $tools 'start-target.ps1') -Name $Name -Minutes 30 -Script motion-target.ps1 | Out-Null }
}

$state = & $vm.Module { param($n) Get-GpuVMState -Name $n } $Name
$client = [ordered]@{}
foreach ($k in $state['config']['streaming']['client'].Keys) { $client[$k] = $state['config']['streaming']['client'][$k] }
$client['displayMode'] = 'borderless'
$fps = [int](& $vm.Module { param($f) Resolve-GpuVMStreamFps $f } $client['fps'])
$arguments = & $vm.Module { param($a, $c) Get-MoonlightStreamArguments -Address $a -Client $c } $vm.Address $client
$results = [System.Collections.Generic.List[object]]::new()
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
try {
    for ($round = 1; $round -le $Rounds; $round++) {
        foreach ($kind in 'gdi', 'gpu') {
            Start-GuestTarget $kind
            $started = Get-Date
            $session = Start-LatencyViewer -Viewer $Viewer -Arguments $arguments
            $firstFrameSec = Wait-LatencyViewerFrame $session -Since $started
            $session.Process.Refresh()
            $window = $session.Process.MainWindowHandle
            if (-not [GpuVMInputMeter]::BringToFront($window)) { 'the viewer is not in front' | Write-Host }
            Start-Sleep -Milliseconds 500
            $bounds = [System.Drawing.Rectangle]::new($screen.Left, $screen.Top, $screen.Width, $screen.Height)
            $wait = [Diagnostics.Stopwatch]::StartNew(); $pictureSec = -1
            while ($wait.Elapsed.TotalSeconds -lt 60) {
                $probe = Measure-Motion -Bounds $bounds -Fps $fps -Seconds 0.5
                if (-not $probe.PSObject.Properties['error']) { $pictureSec = [math]::Round($firstFrameSec + $wait.Elapsed.TotalSeconds, 1); break }
            }
            Start-Sleep -Seconds 2
            $row = Measure-Motion -Bounds $bounds -Fps $fps -Seconds $Seconds
            $row | Add-Member target $kind -PassThru | Add-Member round $round -PassThru | Add-Member viewer $Viewer -PassThru | Add-Member fps $fps -PassThru | Add-Member pictureSec $pictureSec | Out-Null
            $results.Add($row)
            if ($row.PSObject.Properties['error']) { "$kind r$round : $($row.error) (picture $pictureSec s)" | Write-Host }
            else { "$kind r$round : reads/s $($row.readsPerSec) updates/s $($row.updatesPerSec) sd $($row.intervalSdMs) ms p99 $($row.intervalP99Ms) ms stutter $($row.stutterPct) %" | Write-Host }
            Stop-LatencyStream $session -VM $vm
            if ($session.Bridge) { $session.Bridge.Dispose() }
        }
    }
}
finally {
    [pscustomobject]@{ measuredAt = (Get-Date).ToString('o'); vm = $Name; fps = $fps; arguments = ($arguments -join ' '); results = @($results) } |
        ConvertTo-Json -Depth 5 | Set-Content -Path $Out -Encoding utf8
    "saved $Out" | Write-Host
    Start-GuestTarget 'none'
    Invoke-Command -VMName $Name -Credential $vm.Guest -ScriptBlock { Remove-Item C:\GpuVM\bar.html, C:\GpuVM\edge-bar -Recurse -Force -ErrorAction SilentlyContinue }
}
