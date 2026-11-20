# Lab 052, control: does Sunshine's capture start over in a loop on a machine WITHOUT the agent too? A copy of
# agent-tpl taken back to use=none (agent uninstalled, the template's own administrator signs in again), then -Rounds
# rounds of each capture (ddx, wgc, interleaved), -Opens Moonlight opens per round. Per open: Sunshine's capture
# restarts ("Desktop resolution" lines) and whether Moonlight's window shows a picture (its brightness SPREAD, never a
# single mean: GpuVM's empty panel once passed for a picture), within -PictureLimitSec. Moonlight, not GpuVM's viewer
# (the viewer gets its pairing over the app's pipe). This branch's module with the installed agent package and viewer
# (read-only); the copy is deleted at the end. Under the shared lab lock. Run elevated.
param([string]$Template = 'agent-tpl', [string]$Name = 'agent052c', [string]$Session = 'agent-broker', [int]$Opens = 4,
    [int]$Rounds = 2, [int]$PictureLimitSec = 20, [int]$ConnectLimitSec = 420)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$module = Join-Path $root 'src\GpuVM\GpuVM.psd1'
$installed = Join-Path $env:ProgramFiles 'GpuVM\gpuvm'
$viewerExe = Join-Path $installed 'viewer\GpuVMViewer.exe'
$moonlightExe = Join-Path $env:ProgramFiles 'Moonlight Game Streaming\Moonlight.exe'
function Line($what) { Write-Host "$(Get-Date -Format HH:mm:ss.fff) $what" }
$theirs = @(Get-Process Moonlight -ErrorAction SilentlyContinue | ForEach-Object Id)
function Get-LabViewer { @(Get-Process Moonlight -ErrorAction SilentlyContinue | Where-Object { $_.Id -notin $theirs }) }
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class Lab052Ctl {
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
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    // The stream's own window (SDL) of a Moonlight process, not its Qt "connecting" window; zero when none shows.
    public static IntPtr StreamWindow(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) { var sb = new System.Text.StringBuilder(64); GetClassName(h, sb, 64); if (sb.ToString() == "SDL_app") { found = h; return false; } }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    // {mean, spread} of the client area's brightness on a 32x18 grid (PrintWindow: a covering window doesn't matter);
    // null when it can't be read.
    public static double[] Read(IntPtr h) {
        RECT r; if (!GetClientRect(h, out r) || r.R < 64 || r.B < 64) return null;
        int w = r.R, ht = r.B;
        var bi = new BITMAPINFOHEADER { biSize = 40, biWidth = w, biHeight = -ht, biPlanes = 1, biBitCount = 32 };
        IntPtr screen = GetDC(IntPtr.Zero), mem = CreateCompatibleDC(screen), bits;
        IntPtr dib = CreateDIBSection(screen, ref bi, 0, out bits, IntPtr.Zero, 0);
        IntPtr old = SelectObject(mem, dib);
        try {
            if (!PrintWindow(h, mem, 3)) return null;
            double sum = 0, lo = 255, hi = 0; int n = 0;
            for (int y = 1; y <= 18; y++) for (int x = 1; x <= 32; x++) {
                int px = Marshal.ReadInt32(bits, ((y * (ht - 1) / 19) * w + x * (w - 1) / 33) * 4);
                double v = ((px & 0xFF) + ((px >> 8) & 0xFF) + ((px >> 16) & 0xFF)) / 3.0;
                sum += v; n++; if (v < lo) lo = v; if (v > hi) hi = v;
            }
            return new double[] { sum / n, hi - lo };
        } finally { SelectObject(mem, old); DeleteObject(dib); DeleteDC(mem); ReleaseDC(IntPtr.Zero, screen); }
    }
}
'@
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
# Connect-GpuVM in a thread job (its steps to a queue, never to its output), up to -ConnectLimitSec.
function Invoke-LabConnect {
    $steps = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $job = Start-ThreadJob -ArgumentList $steps, $module, $Name, $overrides, $viewerExe, (Join-Path $installed 'guest\agent') {
        param($steps, $mod, $n, $ov, $viewer, $dist)
        Import-Module $mod -Force
        & ([scriptblock]::Create($ov)) $viewer $dist
        $global:GpuVMProgressSink = { param($message) $steps.Enqueue("STEP $message") }.GetNewClosure()
        try { Connect-GpuVM -Name $n 3>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord]) { "WARN $($_.Message)" } else { "OUT" } } }
        catch { "ERROR $($_.Exception.Message)" }
    }
    $t0 = Get-Date; $step = $null
    while ($job.State -in 'NotStarted', 'Running' -and ((Get-Date) - $t0).TotalSeconds -lt $ConnectLimitSec) {
        while ($steps.TryDequeue([ref]$step)) { Line "  $step" }; foreach ($l in @(Receive-Job $job)) { Line "  $l" }
        Start-Sleep -Seconds 2
    }
    while ($steps.TryDequeue([ref]$step)) { Line "  $step" }; $lines = @(Receive-Job $job); $lines | ForEach-Object { Line "  $_" }
    if ($job.State -in 'NotStarted', 'Running') { Stop-Job $job; throw "Connect-GpuVM still running after $ConnectLimitSec s" }
    if ($lines | Where-Object { "$_" -like 'ERROR *' }) { throw "Connect-GpuVM failed" }
    Start-Sleep -Seconds 5
    Get-LabViewer | Stop-Process -Force
}
& (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What "lab 052: capture control on a copy without the agent" -Me $Session -MaxMinutes 180
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
    $state = & $m { param($n) Get-GpuVMState -Name $n } $Name
    $cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
    & $m { param($n, $c) Wait-GuestReady -Name $n -Credential $c } $Name $cred
    # No agent: use none (uninstalls it if a copy has one; the template's administrator signs in again), then off/on.
    $result['use'] = Set-GpuVMUse -Name $Name -Use none
    # An agent template signs nobody in by itself (only `agent`, after its install): the template's administrator signs
    # in automatically on this throwaway copy, as on a machine of one's own (lab only; the copy is deleted at the end).
    $plain = $cred.GetNetworkCredential()
    Invoke-Command -VMName $Name -Credential $cred -ArgumentList $plain.UserName, $plain.Password {
        param($u, $p)
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty $k AutoAdminLogon '1'; Set-ItemProperty $k DefaultUserName $u; Set-ItemProperty $k DefaultPassword $p
        Set-ItemProperty $k DefaultDomainName $env:COMPUTERNAME
    }
    $plain = $null
    & $m { param($n) Restart-GpuVMCold -Name $n } $Name
    & $m { param($n, $c) Wait-GuestReady -Name $n -Credential $c } $Name $cred
    $result['console'] = Invoke-Command -VMName $Name -Credential $cred { "$((Get-CimInstance Win32_ComputerSystem).UserName) | agent service: $((Get-Service GpuVMAgent -ErrorAction SilentlyContinue).Status)" }
    Line "signed in: $($result['console'])"
    $logFile = 'C:\Program Files\Sunshine\config\sunshine.log'
    for ($round = 1; $round -le $Rounds; $round++) {
        foreach ($capture in 'ddx', 'wgc') {
            Line "=== round $round, capture $capture"
            Set-GpuVMCapture -Name $Name -Mode $capture | Out-Null
            Invoke-LabConnect
            $state = & $m { param($n) Get-GpuVMState -Name $n } $Name
            $address = & $m { param($n) Get-GpuVMAddress -Name $n -TimeoutSec 30 } $Name
            $arguments = @(& $m { param($a, $c) Get-MoonlightStreamArguments -Address $a -Client $c } $address $state['config']['streaming']['client']) + @('--display-mode', 'windowed')
            $conf = Invoke-Command -VMName $Name -Credential $cred { @(Get-Content 'C:\Program Files\Sunshine\config\sunshine.conf' | Where-Object { $_ -match '^\s*capture' }) -join ';' }
            Line "sunshine.conf: $conf"
            for ($i = 1; $i -le $Opens; $i++) {
                Get-LabViewer | Stop-Process -Force
                $logBefore = Invoke-Command -VMName $Name -Credential $cred -ArgumentList $logFile { param($f) (Get-Content $f).Count }
                $started = Get-Date
                & $m { param($f, $a) Start-UnelevatedProcess -FilePath $f -ArgumentList $a } $moonlightExe $arguments | Out-Null
                $open = [ordered]@{ round = $round; capture = $capture; n = $i; windowSec = $null; pictureSec = $null; firstSpread = $null; lastSpread = $null }
                while (((Get-Date) - $started).TotalSeconds -lt $PictureLimitSec -and $null -eq $open['pictureSec']) {
                    $p = Get-LabViewer | Select-Object -First 1
                    $hw = if ($p) { [Lab052Ctl]::StreamWindow([uint32]$p.Id) } else { [IntPtr]::Zero }
                    if ($hw -ne [IntPtr]::Zero) {
                        $v = [Lab052Ctl]::Read($hw)
                        $sec = [math]::Round(((Get-Date) - $started).TotalSeconds, 2)
                        # Only the stream's SDL window: Moonlight's own "connecting" screen has contrast too.
                        if ($v) {
                            if ($null -eq $open['windowSec']) { $open['windowSec'] = $sec; $open['firstSpread'] = [math]::Round($v[1], 1) }
                            $open['lastSpread'] = [math]::Round($v[1], 1)
                            if ($v[1] -gt 60) { $open['pictureSec'] = $sec }
                        }
                    }
                    Start-Sleep -Milliseconds 250
                }
                Start-Sleep -Seconds 2
                $log = @(Invoke-Command -VMName $Name -Credential $cred -ArgumentList $logFile, $logBefore { param($f, $from) Get-Content $f | Select-Object -Skip $from })
                $open['captureRestarts'] = @($log | Where-Object { $_ -match 'Desktop resolution' }).Count
                $open['encoders'] = @($log | Where-Object { $_ -match 'Creating encoder' }).Count
                $open['errors'] = @($log | Where-Object { $_ -match 'Error:' } | Select-Object -First 5)
                Line "open $i ($capture): window $($open['windowSec']) s, picture $($open['pictureSec']) s, spread $($open['firstSpread'])->$($open['lastSpread']), capture restarts $($open['captureRestarts']), encoders $($open['encoders'])"
                $result['opens'] += $open
                Get-LabViewer | Stop-Process -Force
                Start-Sleep -Seconds 5
            }
        }
    }
}
catch { $result['error'] = "$($_.Exception.Message)"; Line "ERROR $($result['error'])" }
finally {
    Get-LabViewer | Stop-Process -Force
    if ($made) {
        try { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false; Line "$Name deleted" }
        catch { Line "couldn't delete $Name : $($_.Exception.Message)" }
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out "control-capture-$stamp.json") -Encoding utf8
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Line 'lock released'
}
