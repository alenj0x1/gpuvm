# Lab 077: a machine without Hyper-V through the installed GpuVM (service, module, agent and viewer from Program
# Files, nothing from the repo): New-GpuVM from a template with the hcs backend, start, guest command, GPU, isolation,
# the stream in GpuVM's viewer (a screenshot of its window is kept), shutdown and removal. The release check for the
# HCS path on this PC (where Hyper-V is the default, so the backend is asked for).
#   pwsh -NoProfile -File labs/077-hcs-installed/run.ps1
param([string]$Template = 'normal-tpl', [int]$StreamSec = 20, [ValidateSet('hcs', 'hyperv-gpup')][string]$Backend = 'hcs')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = $PSScriptRoot
$app = 'C:\Program Files\GpuVM'
$exe = Join-Path $app 'gpuvm-host.exe'
$name = 'm077'; $lock = 'C:\GpuVM\.lab-lock'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $here 'out'; $null = New-Item -ItemType Directory -Force $outDir
$res = [ordered]@{ runId = $runId; steps = [ordered]@{} }
$sw = [Diagnostics.Stopwatch]::StartNew()
function Write-Log([string]$m) { Write-Host ("[{0,6:n1}s] {1}" -f $sw.Elapsed.TotalSeconds, $m) }
function Invoke-Step([string]$Key, [scriptblock]$Body) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    try { $v = & $Body; $res.steps[$Key] = [ordered]@{ ok = $true; sec = [math]::Round($t.Elapsed.TotalSeconds, 1) }; Write-Log "$Key ok ($([math]::Round($t.Elapsed.TotalSeconds,1)) s)"; $v }
    catch { $res.steps[$Key] = [ordered]@{ ok = $false; sec = [math]::Round($t.Elapsed.TotalSeconds, 1); error = "$_" }; Write-Log "$Key FAILED: $_"; throw }
}
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Lab077Win {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
}
'@

try { $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) }
catch [IO.IOException] { throw "The lab lock is held: $(Get-Content $lock -Raw)" }
$fs.Write([Text.Encoding]::UTF8.GetBytes("lab077 pid=$PID $(Get-Date -Format o)")); $fs.Close()
try {
    if ((Get-Service GpuVM).Status -ne 'Running') { throw 'the installed GpuVM service is not running' }
    $module = Import-Module (Join-Path $app 'gpuvm\src\GpuVM\GpuVM.psd1') -Force -PassThru -DisableNameChecking
    $res.moduleVersion = "$($module.Version)"
    $res.agentVersion = (Get-Content (Join-Path $app 'gpuvm\guest\agent\dist\VERSION') -Raw).Trim()
    $res.platform = Get-GpuVMPlatform
    Invoke-Step 'new' { New-GpuVM -Name $name -Template $Template -Override @{ backend = $Backend } -Confirm:$false | Out-Null }
    $res.overview = Invoke-Step 'overview' { @(Get-GpuVMOverview | Where-Object { $_['name'] -eq $name } | ForEach-Object { "$($_['name']) $($_['state']) $($_['backend'])" }) }
    $startedAt = Get-Date
    $res.startLog = Invoke-Step 'start' { (Invoke-GpuVMPower -Name $name -Action Start *>&1 | Out-String).Trim() }
    # When the GPU's device went in and when Windows booted, from the host's Hyper-V worker log.
    $res.startEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Hyper-V-Worker-Admin'; StartTime = $startedAt; Id = 33103, 33104, 18601 } -ErrorAction SilentlyContinue |
        Sort-Object TimeCreated | ForEach-Object { '+{0:n1}s {1}' -f ($_.TimeCreated - $startedAt).TotalSeconds, @{ 33103 = 'gpu-added'; 33104 = 'gpu-removed'; 18601 = 'os-booted' }[$_.Id] })
    $cred = & $module { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $name
    Invoke-Step 'ready' { & $module { param($n, $c) Wait-GuestReady -Name $n -Credential $c -TimeoutSec 600 } $name $cred }
    $res.gpuInGuest = Invoke-Step 'gpu' { & $module { param($n, $c) Invoke-Guest -Name $n -Credential $c -ScriptBlock { (Get-CimInstance Win32_VideoController | Where-Object Name -notlike '*Basic*').Name } } $name $cred }
    $router = (Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Sort-Object RouteMetric | Select-Object -First 1).NextHop
    $res.isolation = Invoke-Step 'isolation' {
        & $module { param($n, $c, $r) Invoke-Guest -Name $n -Credential $c -ArgumentList $r -ScriptBlock {
            param($router)
            $deadline = (Get-Date).AddSeconds(90)
            do { $web = & curl.exe -s -o NUL -m 10 -w '%{http_code}' https://www.microsoft.com/; if ($web -ne '200') { Start-Sleep 3 } } while ($web -ne '200' -and (Get-Date) -lt $deadline)
            $lan = & curl.exe -s -o NUL -m 5 -w '%{http_code}' "http://${router}/"; $lanExit = $LASTEXITCODE
            [ordered]@{ internet = $web; lanRouter = "$lan exit=$lanExit" }
        } } $name $cred $router
    }
    if ($res.isolation.internet -ne '200' -or $res.isolation.lanRouter -notmatch 'exit=(7|28)') { throw "isolation: $($res.isolation | ConvertTo-Json -Compress)" }
    $connected = Invoke-Step 'connect' { @(Connect-GpuVM -Name $name 6>$null) }
    # The app opens the viewer inside its window with these arguments; here it opens on its own (no --gpuvm-embed).
    $launch = @($connected | Where-Object { $_ -and $_.PSObject.Properties['viewerLaunch'] } | Select-Object -Last 1).viewerLaunch
    $arguments = [Collections.Generic.List[string]]::new()
    $list = @($launch.arguments)
    for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i] -eq '--gpuvm-embed') { $i++; continue }; $arguments.Add([string]$list[$i]) }
    $res.viewerArgs = $arguments.Count
    $quoted = $arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }
    $null = Start-Process (Join-Path $app 'gpuvm\viewer\GpuVMViewer.exe') -ArgumentList ($quoted -join ' ') -PassThru
    Start-Sleep $StreamSec
    $res.viewerRunning = [bool](Get-Process GpuVMViewer -ErrorAction SilentlyContinue)
    if ($res.viewerRunning) {
        # Only the viewer's own window, drawn by itself (PrintWindow, full content): never the screen.
        $v = Get-Process GpuVMViewer | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
        $r = [Lab077Win+RECT]::new(); $null = [Lab077Win]::GetWindowRect($v.MainWindowHandle, [ref]$r)
        $w = [math]::Max(1, $r.R - $r.L); $h = [math]::Max(1, $r.B - $r.T)
        $bmp = [Drawing.Bitmap]::new($w, $h); $g = [Drawing.Graphics]::FromImage($bmp)
        $hdc = $g.GetHdc(); $res.printed = [Lab077Win]::PrintWindow($v.MainWindowHandle, $hdc, 2); $g.ReleaseHdc($hdc)
        # A picture is not a single flat color: count distinct colors on a coarse grid.
        $colors = [Collections.Generic.HashSet[int]]::new()
        for ($x = 0; $x -lt $w; $x += [math]::Max(1, [int]($w / 40))) { for ($y = 0; $y -lt $h; $y += [math]::Max(1, [int]($h / 40))) { $null = $colors.Add($bmp.GetPixel($x, $y).ToArgb()) } }
        $res.viewerColors = $colors.Count
        $res.viewerSize = "${w}x$h"
        $bmp.Save((Join-Path $outDir "$runId-viewer.png")); $g.Dispose(); $bmp.Dispose()
    }
    Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Stop-Process -Force
    $res.agentLog = @(Get-Content "C:\GpuVM\$name\agent.log" -ErrorAction SilentlyContinue | Select-Object -Last 12)
    $res.shutdownLog = Invoke-Step 'shutdown' { (Invoke-GpuVMPower -Name $name -Action Shutdown *>&1 | Out-String).Trim() }
    Invoke-Step 'remove' { Remove-GpuVM -Name $name -DeleteDisk -Confirm:$false | Out-Null }
    $res.gone = -not (Test-Path "C:\GpuVM\$name")
} catch { $res.error = "$_"; $res.errorAt = $_.InvocationInfo.PositionMessage; Write-Log "FAILED: $_" }
finally {
    Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    if (Test-Path "C:\GpuVM\$name\hcs-machine.json") { & $exe hcs off C:\GpuVM $name | Out-Null; & $exe hcs delete C:\GpuVM $name | Out-Null }
    $res.totalSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $res | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $outDir "$runId.json")
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
    Write-Log "done -> out/$runId.json; left behind: machine=$(Test-Path "C:\GpuVM\$name") lock=$(Test-Path $lock)"
}
