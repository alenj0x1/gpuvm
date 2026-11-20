# Lab 055: one open of GpuVM's viewer on the agent copy, with the arguments Connect-GpuVM gave (out\args.json, made
# with -Prepare, which runs the real Connect-GpuVM -Viewer once). Measures from Sunshine's own log what it did in that
# session (capture restarts = "Desktop resolution", first real frame = "Capture format") and saves the viewer's own
# window (PrintWindow, not the screen: what is on top doesn't count) at 3, 8 and 20 s. Run elevated.
param([string]$Name = 'agent055', [string]$Label = 'open', [switch]$Prepare, [int]$Seconds = 20)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'
Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
$m = Get-Module GpuVM
$installed = Join-Path $env:ProgramFiles 'GpuVM\gpuvm'
$viewer = Join-Path $installed 'viewer\GpuVMViewer.exe'
& $m { param($v) $script:LabViewer = $v; function script:Get-GpuVMViewerPath { $script:LabViewer } } $viewer
$argsFile = Join-Path $out 'args.json'
if ($Prepare) {
    $r = Connect-GpuVM -Name $Name -Viewer
    $r.viewerLaunch.arguments | ConvertTo-Json | Set-Content $argsFile
    "prepared: $($r.viewerLaunch.arguments -join ' ')"
    return
}
$arguments = @(Get-Content $argsFile -Raw | ConvertFrom-Json)
$state = & $m { param($n) Get-GpuVMState -Name $n } $Name
$cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
$logPath = 'C:\Program Files\Sunshine\config\sunshine.log'
# Vibeshine writes config\logs\sunshine-<time>.log; upstream Sunshine config\sunshine.log.
$logPath = Invoke-Command -VMName $Name -Credential $cred -ArgumentList $logPath { param($p) $n = Get-ChildItem 'C:\Program Files\Sunshine\config\logs' -Filter *.log -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($n -and $n.LastWriteTime -gt (Get-Item $p).LastWriteTime) { $n.FullName } else { $p } }
$mark = Invoke-Command -VMName $Name -Credential $cred -ArgumentList $logPath { param($p) @(Get-Content $p -ErrorAction SilentlyContinue).Count }

$shotScript = Join-Path $PSScriptRoot 'shot.ps1'
$sw = [Diagnostics.Stopwatch]::StartNew()
# As the app starts it (tools/latency/common.ps1): private pipe, one-time token, Low integrity, its own pairing.
. (Join-Path $root 'tools\latency\common.ps1')
$t0 = Get-Date
$session = Start-LatencyViewer -Viewer gpuvm -Arguments $arguments
$p = $session.Process
$shots = [ordered]@{}
foreach ($at in 3, 8, $Seconds) {
    while ($sw.Elapsed.TotalSeconds -lt $at) { Start-Sleep -Milliseconds 200 }
    $p.Refresh()
    $file = Join-Path $out "$Label-$at`s.png"
    if ($at -eq $Seconds) { $helpers = Invoke-Command -VMName $Name -Credential $cred { Get-CimInstance Win32_Process -Filter "Name='sunshine_wgc_capture.exe'" | ForEach-Object { $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner; "pid $($_.ProcessId) s$($_.SessionId) $($o.Domain)\$($o.User)" } } }
    $shots["$at s"] = if ($p.MainWindowHandle -ne 0) { (powershell.exe -NoProfile -File $shotScript -Hwnd ([long]$p.MainWindowHandle) -Path $file) } else { 'no-window' }
}
$viewerFirstFrame = if ($session.Bridge.FirstFrameTicks -ge 0) { [math]::Round(([datetime]::new($session.Bridge.FirstFrameTicks, 'Utc') - $t0.ToUniversalTime()).TotalSeconds, 1) } else { $null }
Stop-LatencyViewers
Start-Sleep -Seconds 2
$log = Invoke-Command -VMName $Name -Credential $cred -ArgumentList $logPath, $mark { param($p, $mark) @(Get-Content $p | Select-Object -Skip $mark) }
$result = [ordered]@{
    label             = $Label
    at                = (Get-Date).ToString('s')
    viewerFirstFrameS = $viewerFirstFrame
    wgcHelper         = @($helpers)
    log               = $logPath
    shots             = $shots
    clientConnected   = @($log | Select-String 'CLIENT CONNECTED').Count
    captureRestarts   = @($log | Select-String 'Desktop resolution').Count
    firstFrame        = @($log | Select-String 'Capture format').Count
    errors            = @($log | Select-String 'Error:' | Select-Object -First 5 | ForEach-Object Line)
    captureLines      = @($log | Select-String -Pattern 'WGC|wgc helper|helper|fallback|DXGI' | Select-Object -First 6 | ForEach-Object Line)
}
$result | ConvertTo-Json -Depth 4 | Tee-Object (Join-Path $out "$Label.json")
