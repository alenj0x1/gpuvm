Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force -DisableNameChecking

function Get-LatencyVM {
    param([Parameter(Mandatory)][string]$Name)
    $module = Get-Module GpuVM
    $state = & $module { param($n) Get-GpuVMState -Name $n } $Name
    $guest = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state
    if (-not $guest) { throw "Save the Windows password of '$Name' in GpuVM first." }
    [pscustomobject]@{
        Name    = $Name
        Module  = $module
        Guest   = $guest
        Address = & $module { param($n) Get-GpuVMAddress -Name $n } $Name
        Sunshine = & $module { param($s) Get-SunshineCredential -State $s } $state
    }
}

function Get-LatencyVariants {
    @(
        [pscustomobject]@{ Name = 'baseline-60-vsync'; Fps = 60; VSync = $true }
        [pscustomobject]@{ Name = 'candidate-60-novsync'; Fps = 60; VSync = $false }
        [pscustomobject]@{ Name = 'candidate-120-novsync'; Fps = 120; VSync = $false }
        [pscustomobject]@{ Name = 'candidate-144-novsync'; Fps = 144; VSync = $false }
    )
}

function Start-LatencyStream {
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)]$Variant,
        [string]$App = 'Desktop',
        [switch]$Overlay
    )
    Get-Process Moonlight -ErrorAction SilentlyContinue | Stop-Process -Force
    $result = & $VM.Module { param($n, $c, $f) Set-GuestDisplayResolution -Name $n -Credential $c -Resolution '1920x1080' -Fps $f } $VM.Name $VM.Guest $Variant.Fps
    $applied = if ($result.PSObject.Properties['applied']) { $result.applied } else { "not applied: $($result.error)" }
    Start-Sleep -Seconds 2
    $moonlight = Join-Path $env:ProgramFiles 'Moonlight Game Streaming\Moonlight.exe'
    $arguments = @('stream', $VM.Address, $App, '--resolution', '1920x1080', '--fps', "$($Variant.Fps)", '--display-mode', 'borderless', '--no-frame-pacing')
    $arguments += if ($Variant.VSync) { '--vsync' } else { '--no-vsync' }
    $arguments += if ($Overlay) { '--performance-overlay' } else { '--no-performance-overlay' }
    $process = Start-Process $moonlight -ArgumentList $arguments -PassThru
    [pscustomobject]@{ Process = $process; Display = $applied }
}

# Changing the refresh rate under a session still open in Sunshine leaves the next stream black: close it there too.
function Stop-LatencyStream {
    param([Parameter(Mandatory)]$Session, $VM)
    Stop-Process -Id $Session.Process.Id -Force -ErrorAction SilentlyContinue
    if ($VM) {
        try { & $VM.Module { param($a, $c) Invoke-SunshineApi -Address $a -Credential $c -Method POST -Path '/api/apps/close' } $VM.Address $VM.Sunshine | Out-Null }
        catch { Write-Warning "Sunshine did not close the session: $($_.Exception.Message)" }
    }
    Start-Sleep -Seconds 4
}

function Save-ScreenRegion {
    param([Parameter(Mandatory)][string]$Path, [int]$X = 0, [int]$Y = 0, [int]$Width, [int]$Height)
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    if (-not $Width) { $Width = $bounds.Width }
    if (-not $Height) { $Height = $bounds.Height }
    $bmp = New-Object System.Drawing.Bitmap $Width, $Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.Left + $X, $bounds.Top + $Y, 0, 0, $bmp.Size)
    $g.Dispose()
    $bmp.Save($Path)
    $bmp.Dispose()
}

if (-not ('GpuVMLatency' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class GpuVMLatency {
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("gdi32.dll")] static extern uint GetPixel(IntPtr dc, int x, int y);

    public static int Brightness(int x, int y) {
        IntPtr dc = GetDC(IntPtr.Zero);
        uint c = GetPixel(dc, x, y);
        ReleaseDC(IntPtr.Zero, dc);
        return (int)(((c & 0xFF) + ((c >> 8) & 0xFF) + ((c >> 16) & 0xFF)) / 3);
    }

    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);

    public static void Key(byte vk) {
        keybd_event(vk, 0, 0, UIntPtr.Zero);
        keybd_event(vk, 0, 2, UIntPtr.Zero);
    }

    public static double Measure(int px, int py, bool expectLit, int timeoutMs) {
        var watch = Stopwatch.StartNew();
        Key(0x91);
        while (watch.ElapsedMilliseconds < timeoutMs) {
            bool lit = Brightness(px, py) > 128;
            if (lit == expectLit) return watch.Elapsed.TotalMilliseconds;
        }
        return -1;
    }
}
'@
}

function Wait-LatencyStreamVisible {
    param([Parameter(Mandatory)][datetime]$Since, [int]$TimeoutSec = 90,
        [string]$LogDir = $env:TEMP)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $log = Get-ChildItem $LogDir -Filter 'Moonlight*.log' -ErrorAction SilentlyContinue |
            Where-Object LastWriteTime -ge $Since | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($log -and (Select-String -LiteralPath $log.FullName -Pattern 'Video stream is' -Quiet)) { return [math]::Round($watch.Elapsed.TotalSeconds, 1) }
        Start-Sleep -Milliseconds 500
    }
    -1
}

function Get-LatencyViewerLogDir([string]$Viewer) {
    if ($Viewer -eq 'gpuvm') { Join-Path $env:USERPROFILE 'AppData\LocalLow\GpuVM\Viewer\logs' } else { $env:TEMP }
}

function Stop-LatencyViewers { Get-Process Moonlight, GpuVMViewer -ErrorAction SilentlyContinue | Stop-Process -Force }

if (-not ('GpuVMLatencyBridge' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.IO.Pipes;
using System.Threading;
// Keeps reading so the viewer's queue never fills.
public class GpuVMLatencyBridge : IDisposable {
    readonly NamedPipeServerStream server;
    readonly string token;
    public volatile bool Hello;
    public long FirstFrameTicks = -1;
    public volatile string LastStats;
    public readonly System.Collections.Concurrent.ConcurrentQueue<string> Stats = new System.Collections.Concurrent.ConcurrentQueue<string>();
    public readonly System.Collections.Concurrent.ConcurrentQueue<string> Events = new System.Collections.Concurrent.ConcurrentQueue<string>();
    readonly object writeLock = new object();
    public bool Send(string json) {
        try { lock (writeLock) { var b = System.Text.Encoding.UTF8.GetBytes(json + "\n"); server.Write(b, 0, b.Length); server.Flush(); } return true; }
        catch { return false; }
    }
    [System.Runtime.InteropServices.DllImport("advapi32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string sddl, uint rev, out IntPtr sd, IntPtr size);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    static extern Microsoft.Win32.SafeHandles.SafePipeHandle CreateNamedPipeW(string name, uint open, uint mode, uint max, uint outSize, uint inSize, uint timeout, ref SECURITY_ATTRIBUTES sa);
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public int bInheritHandle; }
    // Labelled Low so the viewer (which lowers itself to Low in GpuVM mode) can open it.
    public GpuVMLatencyBridge(string name, string token) {
        this.token = token;
        string user = System.Security.Principal.WindowsIdentity.GetCurrent().User.Value;
        IntPtr sd;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW("D:P(A;;GA;;;" + user + ")S:(ML;;NW;;;LW)", 1, out sd, IntPtr.Zero)) throw new Exception("security descriptor");
        var sa = new SECURITY_ATTRIBUTES { nLength = System.Runtime.InteropServices.Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)), lpSecurityDescriptor = sd };
        // PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE | FILE_FLAG_OVERLAPPED; PIPE_TYPE_BYTE | PIPE_REJECT_REMOTE_CLIENTS
        var handle = CreateNamedPipeW(@"\\.\pipe\" + name, 0x3 | 0x80000 | 0x40000000, 0x8, 1, 65536, 65536, 0, ref sa);
        LocalFree(sd);
        if (handle.IsInvalid) throw new Exception("pipe " + System.Runtime.InteropServices.Marshal.GetLastWin32Error());
        server = new NamedPipeServerStream(PipeDirection.InOut, true, false, handle);
        new Thread(Run) { IsBackground = true }.Start();
    }
    void Run() {
        try {
            server.WaitForConnection();
            var reader = new StreamReader(server);
            string line;
            while ((line = reader.ReadLine()) != null) {
                if (!Hello) { Hello = line.Contains(token); continue; }
                if (FirstFrameTicks < 0 && line.Contains("\"first-frame\"")) FirstFrameTicks = DateTime.UtcNow.Ticks;
                if (line.Contains("\"stats\"")) { LastStats = line; Stats.Enqueue(line); }
                else Events.Enqueue(line);
            }
        } catch { }
    }
    public void Dispose() { try { server.Dispose(); } catch { } }
}
"@
}

function Start-LatencyViewer {
    # -Quiet: GpuVM's viewer started from a console logs every decoder line into it.
    param([Parameter(Mandatory)][ValidateSet('moonlight', 'gpuvm')][string]$Viewer, [Parameter(Mandatory)][string[]]$Arguments, [switch]$Quiet)
    Stop-LatencyViewers
    if ($Viewer -eq 'moonlight') {
        $process = Start-Process (Join-Path $env:ProgramFiles 'Moonlight Game Streaming\Moonlight.exe') -ArgumentList $Arguments -PassThru
        return [pscustomobject]@{ Process = $process; Viewer = $Viewer; Bridge = $null }
    }
    $exe = (Resolve-Path (Join-Path $PSScriptRoot '..\..\viewer\GpuVMViewer.exe')).Path
    $hex = { param($n) $b = [byte[]]::new($n); [Security.Cryptography.RandomNumberGenerator]::Fill($b); -join ($b | ForEach-Object { $_.ToString('x2') }) }
    $name = 'gpuvm-viewer-' + (& $hex 16)
    $token = & $hex 32
    $bridge = [GpuVMLatencyBridge]::new($name, $token)
    $psi = [Diagnostics.ProcessStartInfo]::new($exe)
    foreach ($a in @($Arguments) + @('--gpuvm-pipe', "\\.\pipe\$name", '--gpuvm-token-env', 'GPUVM_VIEWER_TOKEN')) { $psi.ArgumentList.Add($a.Trim('"')) }
    $psi.Environment['GPUVM_VIEWER_TOKEN'] = $token
    $psi.UseShellExecute = $false
    if ($Quiet) { $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true }
    $process = [Diagnostics.Process]::Start($psi)
    if ($Quiet) {
        # Drained by .NET tasks, so a full pipe never blocks the viewer.
        [void]$process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
        [void]$process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
    }
    [pscustomobject]@{ Process = $process; Viewer = $Viewer; Bridge = $bridge }
}

function Wait-LatencyViewerFrame {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][datetime]$Since, [int]$TimeoutSec = 90)
    if (-not $Session.Bridge) { return Wait-LatencyStreamVisible -Since $Since -TimeoutSec $TimeoutSec -LogDir (Get-LatencyViewerLogDir $Session.Viewer) }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if ($Session.Bridge.FirstFrameTicks -ge 0) { return [math]::Round(([datetime]::new($Session.Bridge.FirstFrameTicks, 'Utc') - $Since.ToUniversalTime()).TotalSeconds, 1) }
        Start-Sleep -Milliseconds 200
    }
    -1
}

function Assert-LatencyGpuIdle {
    param([int]$MaxPct = 10, [int]$WaitSec = 30, [switch]$Force)
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) { return $null }
    $deadline = (Get-Date).AddSeconds($WaitSec)
    do {
        $pct = @(1..5 | ForEach-Object { [int](& $smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | Select-Object -First 1); Start-Sleep -Milliseconds 200 } | Measure-Object -Average).Average
        if ($pct -le $MaxPct) { return [math]::Round($pct, 1) }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    $users = Get-Counter '\GPU Engine(*engtype_3d)\Utilization Percentage' -ErrorAction SilentlyContinue | ForEach-Object { $_.CounterSamples } |
        Where-Object CookedValue -gt 1 | ForEach-Object { if ($_.InstanceName -match 'pid_(\d+)_') { [pscustomobject]@{ Pid = [int]$Matches[1]; Pct = $_.CookedValue } } } |
        Group-Object Pid | ForEach-Object { $p = Get-Process -Id $_.Name -ErrorAction SilentlyContinue; "$(if ($p) { $p.Name } else { $_.Name }) $([math]::Round(($_.Group | Measure-Object Pct -Sum).Sum)) %" }
    $message = "The host GPU is $([math]::Round($pct)) % busy without a stream ($((@($users) | Select-Object -First 6) -join ', ')). Close what draws on it, or pass -Force."
    if ($Force) { Write-Warning $message; return [math]::Round($pct, 1) }
    throw $message
}

function Get-LatencyViewerStats {
    param([Parameter(Mandatory)]$Session, [int]$LastSeconds = 15)
    if (-not $Session.Bridge) { return $null }
    $rows = @($Session.Bridge.Stats.ToArray() | Select-Object -Last $LastSeconds | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ })
    if (-not $rows) { return $null }
    $avg = [ordered]@{ samples = $rows.Count }
    foreach ($k in 'receivedFps', 'renderedFps', 'networkDropPercent', 'decodeMs', 'renderMs', 'hostLatencyMs', 'networkLatencyMs') {
        $v = @($rows | ForEach-Object { $_.$k } | Where-Object { $null -ne $_ })
        if ($v) { $avg[$k] = [math]::Round(($v | Measure-Object -Average).Average, 2) }
    }
    [pscustomobject]$avg
}
