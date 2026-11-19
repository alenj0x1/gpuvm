# Lab 052: Open on a copy of agent-tpl with this branch's module (a standard user signed in: Sunshine captures as a
# service, ddx). Checks that Connect-GpuVM finishes and Sunshine runs as SYSTEM, then opens Moonlight (windowed) -Opens
# times and follows its window's brightness (PrintWindow, so a covering window doesn't matter) next to Moonlight's
# "Video stream is" (first frame received) and Sunshine's log, to see whether DDX's first picture stays black.
# GpuVM's viewer can't be used from here: it gets its pairing identity from the app over a pipe (run 3 showed its
# "not paired" dialog). Moonlight talks to the same Sunshine. The installed agent package is used read-only (this
# worktree has none); nothing installed is changed. The copy (3 GB) is deleted at the end.
# Under the shared lab lock. Run elevated.
param([string]$Template = 'agent-tpl', [string]$Name = 'agent052d', [string]$Session = 'agent-broker', [int]$Opens = 3,
    [int]$ConnectLimitSec = 420, [int]$PictureLimitSec = 40)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$module = Join-Path $root 'src\GpuVM\GpuVM.psd1'
$installed = Join-Path $env:ProgramFiles 'GpuVM\gpuvm'
$viewerExe = Join-Path $installed 'viewer\GpuVMViewer.exe'
$moonlightExe = Join-Path $env:ProgramFiles 'Moonlight Game Streaming\Moonlight.exe'
function Line($what) { Write-Host "$(Get-Date -Format HH:mm:ss.fff) $what" }
if (-not (Test-Path $viewerExe)) { throw "no installed viewer at $viewerExe" }
# Moonlight windows already open (the person's) are never touched: only the ones this lab starts are closed.
$theirs = @(Get-Process Moonlight -ErrorAction SilentlyContinue | ForEach-Object Id)
function Get-LabViewer { @(Get-Process Moonlight -ErrorAction SilentlyContinue | Where-Object { $_.Id -notin $theirs }) }
# Plain GDI (System.Drawing isn't loadable from Add-Type in this PowerShell).
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class Lab052Shot {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct BITMAPINFOHEADER { public int biSize, biWidth, biHeight; public short biPlanes, biBitCount; public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant; }
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BITMAPINFOHEADER bi, uint usage, out IntPtr bits, IntPtr section, uint offset);
    // Mean brightness (0-255) of the window's client area, from a 32x18 grid; -1 when it can't be read.
    public static double Brightness(IntPtr h) {
        RECT r; if (!GetClientRect(h, out r) || r.R < 64 || r.B < 64) return -1;
        int w = r.R, ht = r.B;
        var bi = new BITMAPINFOHEADER { biSize = 40, biWidth = w, biHeight = -ht, biPlanes = 1, biBitCount = 32 };
        IntPtr screen = GetDC(IntPtr.Zero), mem = CreateCompatibleDC(screen), bits;
        IntPtr dib = CreateDIBSection(screen, ref bi, 0, out bits, IntPtr.Zero, 0);
        IntPtr old = SelectObject(mem, dib);
        try {
            if (!PrintWindow(h, mem, 3)) return -1;
            double sum = 0; int n = 0;
            for (int y = 1; y <= 18; y++) for (int x = 1; x <= 32; x++) {
                int px = Marshal.ReadInt32(bits, ((y * (ht - 1) / 19) * w + x * (w - 1) / 33) * 4);
                sum += ((px & 0xFF) + ((px >> 8) & 0xFF) + ((px >> 16) & 0xFF)) / 3.0; n++;
            }
            return sum / n;
        } finally { SelectObject(mem, old); DeleteObject(dib); DeleteDC(mem); ReleaseDC(IntPtr.Zero, screen); }
    }
}
'@
# The module's lookups for the viewer and the agent package point at the installed copies, inside this session only.
$overrides = {
    param($viewer, $dist)
    $m = Get-Module GpuVM
    & $m {
        param($viewer, $dist)
        $script:LabViewer = $viewer; $script:LabDist = $dist
        function script:Get-GpuVMViewerPath { $script:LabViewer }
        function script:Get-RepoPath { param($Relative) if ($Relative -eq 'guest\agent') { $script:LabDist } else { Join-Path $script:RepoRoot $Relative } }
    } $viewer $dist
}
& (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What "lab 052: Open with ddx on a copy of $Template" -Me $Session -MaxMinutes 120
if ($LASTEXITCODE) { throw 'no lock' }
$made = $false
$result = [ordered]@{ module = "$(git -C $root rev-parse --short HEAD)"; opens = @() }
try {
    Import-Module $module -Force
    & $overrides $viewerExe (Join-Path $installed 'guest\agent')
    $m = Get-Module GpuVM
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false }
    New-GpuVM -Name $Name -Template $Template | Out-Null
    $made = $true
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes 3GB
    Start-VM -Name $Name
    $t0 = Get-Date
    $steps = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $job = Start-ThreadJob -ArgumentList $steps, $module, $Name, $overrides, $viewerExe, (Join-Path $installed 'guest\agent') {
        param($steps, $mod, $n, $ov, $viewer, $dist)
        Import-Module $mod -Force
        & ([scriptblock]::Create($ov)) $viewer $dist
        # The steps go to a queue the lab reads, never to the output: Write-Step runs inside Connect-GpuVM, and output
        # there would end up in its variables (lab 052: "drive STEP 04 not found").
        $global:GpuVMProgressSink = { param($message) $steps.Enqueue("STEP $(Get-Date -Format HH:mm:ss.fff) $message") }.GetNewClosure()
        try { Connect-GpuVM -Name $n 3>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord]) { "WARN $($_.Message)" } elseif ($_ -is [string]) { $_ } else { "RESULT $($_ | ConvertTo-Json -Compress -Depth 5)" } } }
        catch { "ERROR $($_.Exception.Message)" }
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $step = $null
    while ($job.State -in 'NotStarted', 'Running' -and ((Get-Date) - $t0).TotalSeconds -lt $ConnectLimitSec) {
        while ($steps.TryDequeue([ref]$step)) { $lines.Add($step); Line $step }; foreach ($l in @(Receive-Job $job)) { $lines.Add("$l"); Line "$l" }
        Start-Sleep -Seconds 2
    }
    while ($steps.TryDequeue([ref]$step)) { $lines.Add($step); Line $step }; foreach ($l in @(Receive-Job $job)) { $lines.Add("$l"); Line "$l" }
    $result['connectFinished'] = $job.State -notin 'NotStarted', 'Running'
    $result['connectSec'] = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    $result['connectLines'] = @($lines)
    if (-not $result['connectFinished']) { Stop-Job $job; throw "Connect-GpuVM still running after $ConnectLimitSec s" }
    if ($lines | Where-Object { $_ -like 'ERROR *' }) { throw "Connect-GpuVM failed" }
    $state = & $m { param($n) Get-GpuVMState -Name $n } $Name
    $address = & $m { param($n) Get-GpuVMAddress -Name $n -TimeoutSec 30 } $Name
    $arguments = @(& $m { param($a, $c) Get-MoonlightStreamArguments -Address $a -Client $c } $address $state['config']['streaming']['client']) + @('--display-mode', 'windowed')
    $result['arguments'] = $arguments
    Start-Sleep -Seconds 5
    Get-LabViewer | Stop-Process -Force
    $cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
    $probe = {
        [ordered]@{
            processes = @(Get-CimInstance Win32_Process -Filter "Name='sunshine.exe'" | ForEach-Object { $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner; "session $($_.SessionId) $($o.Domain)\$($o.User)" })
            service = "$((Get-Service SunshineService).Status) $((Get-Service SunshineService).StartType)"
            task = @(Get-ScheduledTask -TaskName 'GpuVM-Sunshine-User' -ErrorAction SilentlyContinue | ForEach-Object { "$($_.State) $($_.Principal.UserId)" })
            capture = @(Get-Content 'C:\Program Files\Sunshine\config\sunshine.conf' | Where-Object { $_ -match '^\s*capture' })
            listening = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -in 47989, 47990 | ForEach-Object LocalPort)
            console = (Get-CimInstance Win32_ComputerSystem).UserName
        }
    }
    $result['guest'] = Invoke-Command -VMName $Name -Credential $cred $probe
    Line "guest: $($result['guest'] | ConvertTo-Json -Compress)"

    for ($i = 1; $i -le $Opens; $i++) {
        Get-LabViewer | Stop-Process -Force
        $logBefore = Invoke-Command -VMName $Name -Credential $cred { (Get-Content 'C:\Program Files\Sunshine\config\sunshine.log').Count }
        $started = Get-Date
        & $m { param($f, $a) Start-UnelevatedProcess -FilePath $f -ArgumentList $a } $moonlightExe $arguments | Out-Null
        # The whole brightness trace (time, value, window title) is kept: the viewer's own "connecting" screen is not
        # black either, so the picture is read from the trace and Sunshine's log, not from a single threshold.
        $open = [ordered]@{ n = $i; windowSec = $null; samples = 0; unreadable = 0; trace = [System.Collections.Generic.List[string]]::new() }
        $lastB = -100; $lastTitle = ''
        while (((Get-Date) - $started).TotalSeconds -lt $PictureLimitSec) {
            $p = Get-LabViewer | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
            if ($p) {
                $sec = [math]::Round(((Get-Date) - $started).TotalSeconds, 2)
                if ($null -eq $open['windowSec']) { $open['windowSec'] = $sec }
                $b = [Lab052Shot]::Brightness($p.MainWindowHandle)
                $open['samples']++
                if ($b -lt 0) { $open['unreadable']++ }
                elseif ([math]::Abs($b - $lastB) -ge 3 -or $p.MainWindowTitle -ne $lastTitle) {
                    $open['trace'].Add("$sec s: $([math]::Round($b, 1)) '$($p.MainWindowTitle)' $($p.Id)")
                    $lastB = $b; $lastTitle = $p.MainWindowTitle
                }
            }
            Start-Sleep -Milliseconds 250
        }
        $open['trace'] = @($open['trace'])
        # Moonlight's own log: when the first frame arrived (black or not) and anything that went wrong.
        $mlog = Get-ChildItem $env:TEMP -Filter 'Moonlight-*.log' | Where-Object LastWriteTime -ge $started | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $open['moonlightLog'] = if ($mlog) { @(Get-Content $mlog.FullName | Where-Object { $_ -match 'Video stream is|Critical|error|fail|IDR|resolution|Launch' } | Select-Object -First 30) } else { @('no log') }
        Start-Sleep -Seconds 3
        $open['sunshineLog'] = @(Invoke-Command -VMName $Name -Credential $cred -ArgumentList $logBefore {
                param($from) Get-Content 'C:\Program Files\Sunshine\config\sunshine.log' | Select-Object -Skip $from | Select-Object -First 120 })
        $open['captureRestarts'] = @($open['sunshineLog'] | Where-Object { $_ -match 'Desktop resolution' }).Count
        Line "open ${i}: window $($open['windowSec']) s, $($open['samples']) samples ($($open['unreadable']) unreadable), capture restarts $($open['captureRestarts']), sunshine lines $($open['sunshineLog'].Count)"; $open['trace'] | ForEach-Object { Line "  $_" }; $open['moonlightLog'] | ForEach-Object { Line "  moonlight: $_" }
        $result['opens'] += $open
        Get-LabViewer | Stop-Process -Force
        Start-Sleep -Seconds 5
    }
}
catch { $result['error'] = "$($_.Exception.Message)"; Line "ERROR $($result['error'])" }
finally {
    Get-LabViewer | Stop-Process -Force
    if ($made) {
        try { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false; Line "$Name deleted" }
        catch { Line "couldn't delete $Name : $($_.Exception.Message)" }
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out "connect-ddx-$stamp.json") -Encoding utf8
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Line 'lock released'
}
