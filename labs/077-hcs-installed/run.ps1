# Lab 077: a machine without Hyper-V through the installed GpuVM (service, module, agent and viewer from Program
# Files, nothing from the repo): New-GpuVM from a template with the hcs backend, start, guest command, GPU, isolation,
# the stream in GpuVM's viewer (a screenshot of its window is kept), shutdown and removal. The release check for the
# HCS path on this PC (where Hyper-V is the default, so the backend is asked for).
#   pwsh -NoProfile -File labs/077-hcs-installed/run.ps1
param([string]$Template = 'normal-tpl', [int]$StreamSec = 20)
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
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Lab077Win {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
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
    Invoke-Step 'new' { New-GpuVM -Name $name -Template $Template -Override @{ backend = 'hcs' } -Confirm:$false | Out-Null }
    $res.overview = Invoke-Step 'overview' { @(Get-GpuVMOverview | Where-Object { $_['name'] -eq $name } | ForEach-Object { "$($_['name']) $($_['state']) $($_['backend'])" }) }
    Invoke-Step 'start' { Invoke-GpuVMPower -Name $name -Action Start | Out-Null }
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
    Invoke-Step 'connect' { Connect-GpuVM -Name $name | Out-Null }
    Start-Sleep $StreamSec
    $viewer = Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
    $res.viewerRunning = [bool]$viewer
    if ($viewer) {
        $r = [Lab077Win+RECT]::new(); $null = [Lab077Win]::GetWindowRect($viewer.MainWindowHandle, [ref]$r)
        $w = [math]::Max(1, $r.R - $r.L); $h = [math]::Max(1, $r.B - $r.T)
        $bmp = [Drawing.Bitmap]::new($w, $h); $g = [Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
        # A picture is not a single flat color: count distinct colors on a coarse grid.
        $colors = [Collections.Generic.HashSet[int]]::new()
        for ($x = 0; $x -lt $w; $x += [math]::Max(1, [int]($w / 40))) { for ($y = 0; $y -lt $h; $y += [math]::Max(1, [int]($h / 40))) { $null = $colors.Add($bmp.GetPixel($x, $y).ToArgb()) } }
        $res.viewerColors = $colors.Count
        $bmp.Save((Join-Path $outDir "$runId-viewer.png")); $g.Dispose(); $bmp.Dispose()
    }
    Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Stop-Process -Force
    Invoke-Step 'shutdown' { Invoke-GpuVMPower -Name $name -Action Shutdown | Out-Null }
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
