# Lab 014: do the speaker's short underruns (about 2 ms, lab 013) reach what Moonlight plays on this PC?
# No questions asked; results go to out\lab-*.json and the VM is left with the speaker as Sunshine's sink.
# For each sink (GpuVM's speaker, then Steam Streaming Speakers as the control when the VM has it), the VM plays a
# steady 440 Hz tone while this PC records its own output by WASAPI loopback (Moonlight is what plays there; keep
# everything else on this PC silent). The recording is checked 1 ms at a time:
#   - gaps: 1 ms windows whose level falls under 30 % of the tone;
#   - breaks: samples where the wave jumps, found with the predictor x[n] = 2cos(w)x[n-1] - x[n-2], which is exact
#     for a pure sine, so a skip, a repeat or an inserted silence leaves a spike in its error.
# Each event is then matched against the speaker's underruns (logged with their UTC time by the server), shifted
# by the end-to-end latency measured in lab 013.
# Elevated, PowerShell 7: pwsh -File labs\014-audible-underruns\lab.ps1 [-Minutes 10] [-ControlMinutes 5]
param(
    [string]$Name = (Get-VM | Where-Object Notes -like "Creada con GpuVM*" | Select-Object -First 1).Name,
    [int]$Minutes = 10,
    [int]$ControlMinutes = 5,
    # Lab 013: median time from the VM playing a sound to Moonlight on this PC.
    [double]$LatencyMs = 63,
    [string]$OutFile = (Join-Path $PSScriptRoot "out\lab-$(Get-Date -Format yyyyMMdd-HHmmss).json")
)
$ErrorActionPreference = 'Stop'
$repo = Join-Path $PSScriptRoot '..\..'
Import-Module (Join-Path $repo 'src\GpuVM\GpuVM.psd1') -Force
$module = Get-Module GpuVM
$report = [ordered]@{ vm = $Name; startedAt = (Get-Date).ToString('o'); minutes = $Minutes; controlMinutes = $ControlMinutes; runs = @() }

# Opened the way the app does it: this also installs or updates the speaker (this lab needs its underrun log).
Connect-GpuVM -Name $Name
$state = & $module { param($n) Get-GpuVMState -Name $n } $Name
$guest = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state
$sunshine = & $module { param($s) Get-SunshineCredential -State $s } $state
$endpoint = & $module { param($n) Get-GpuVMEndpoint -Name $n -TimeoutSec 60 } $Name
$moonlight = & $module { Get-MoonlightPath }
$arguments = & $module { param($a, $c) Get-MoonlightStreamArguments -Address $a -Client $c } $endpoint.Address $state['config']['streaming']['client']
$streamingCode = Get-Content -Raw (Join-Path $repo 'guest\streaming.ps1')

# This PC: loopback of the default output, analysed while it records (10 minutes of float stereo would be 230 MB).
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
public static class OutputRecorder {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class En {}
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator { [PreserveSig] int EnumAudioEndpoints(int f, int m, out IntPtr c); [PreserveSig] int GetDefaultAudioEndpoint(int f, int r, out IMMDevice d); }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice { [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); }
    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient {
        [PreserveSig] int Initialize(int share, int flags, long dur, long period, IntPtr fmt, IntPtr session);
        [PreserveSig] int GetBufferSize(out uint n); [PreserveSig] int GetStreamLatency(out long l); [PreserveSig] int GetCurrentPadding(out uint p);
        [PreserveSig] int IsFormatSupported(int s, IntPtr f, out IntPtr c); [PreserveSig] int GetMixFormat(out IntPtr f); [PreserveSig] int GetDevicePeriod(out long d, out long m);
        [PreserveSig] int Start(); [PreserveSig] int Stop(); [PreserveSig] int Reset(); [PreserveSig] int SetEventHandle(IntPtr h);
        [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object o);
    }
    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioCaptureClient {
        [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out uint flags, out long pos, out long qpc);
        [PreserveSig] int ReleaseBuffer(uint n); [PreserveSig] int GetNextPacketSize(out uint n);
    }

    static Thread thread;
    static volatile bool running;
    public static int Rate, Channels;
    public static long StartTicks, Frames, Discontinuities;
    public static string Error;
    // Per 1 ms window: RMS of the first channel and the largest predictor error in it.
    public static List<float> Rms = new List<float>(), Residual = new List<float>();

    public static void Start() {
        Rms = new List<float>(); Residual = new List<float>(); Frames = 0; Discontinuities = 0; Error = null;
        var e = (IMMDeviceEnumerator)new En(); IMMDevice d; Marshal.ThrowExceptionForHR(e.GetDefaultAudioEndpoint(0, 0, out d));
        var iid = typeof(IAudioClient).GUID; object o; Marshal.ThrowExceptionForHR(d.Activate(ref iid, 23, IntPtr.Zero, out o));
        var ac = (IAudioClient)o;
        IntPtr mix; Marshal.ThrowExceptionForHR(ac.GetMixFormat(out mix));
        Channels = Marshal.ReadInt16(mix, 2); Rate = Marshal.ReadInt32(mix, 4);
        int bits = Marshal.ReadInt16(mix, 14);
        if (bits != 32) throw new InvalidOperationException("the output's mix format is not float32");
        Marshal.ThrowExceptionForHR(ac.Initialize(0, 0x00020000, 10000000, 0, mix, IntPtr.Zero));
        var cid = typeof(IAudioCaptureClient).GUID; object co; Marshal.ThrowExceptionForHR(ac.GetService(ref cid, out co));
        var cc = (IAudioCaptureClient)co;
        double c2 = 2 * Math.Cos(2 * Math.PI * 440 / Rate);
        running = true;
        thread = new Thread(() => {
            try {
                // Windows end on whole milliseconds of samples, so window i is millisecond i at any rate.
                double x1 = 0, x2 = 0, sum = 0, worst = 0; int inWindow = 0; long n = 0;
                ac.Start();
                StartTicks = DateTime.UtcNow.Ticks;
                while (running) {
                    uint size; cc.GetNextPacketSize(out size);
                    while (size > 0) {
                        IntPtr data; uint nf, flags; long p, q; cc.GetBuffer(out data, out nf, out flags, out p, out q);
                        if ((flags & 1) != 0) Discontinuities++;
                        var buf = new float[nf * Channels];
                        if ((flags & 2) == 0) Marshal.Copy(data, buf, 0, buf.Length);
                        for (int i = 0; i < nf; i++) {
                            double x = buf[i * Channels];
                            double r = Math.Abs(x - c2 * x1 + x2);
                            x2 = x1; x1 = x;
                            sum += x * x; if (r > worst) worst = r;
                            inWindow++; n++;
                            if (n * 1000 / Rate != (n - 1) * 1000 / Rate) {
                                Rms.Add((float)Math.Sqrt(sum / inWindow)); Residual.Add((float)worst);
                                sum = 0; worst = 0; inWindow = 0;
                            }
                        }
                        Frames += nf;
                        cc.ReleaseBuffer(nf); cc.GetNextPacketSize(out size);
                    }
                    Thread.Sleep(5);
                }
                ac.Stop();
            } catch (Exception ex) { Error = ex.Message; }
        });
        thread.IsBackground = true; thread.Start();
    }
    public static void Stop() { running = false; if (thread != null) thread.Join(); }

    static float Median(List<float> v, int from, int to) {
        var s = v.GetRange(from, to - from); s.Sort(); return s[s.Count / 2];
    }
    // Events between two window indexes, skipping the given ranges: [kind, window index, length or size].
    public static List<double[]> Events(int from, int to, List<int[]> skip) {
        var r = new List<double[]>();
        float level = Median(Rms, from, to), noise = Median(Residual, from, to);
        // A break is an error well above the coding noise and at least 5 % of the tone's peak.
        double breakAt = Math.Max(10 * noise, 0.05 * level * Math.Sqrt(2));
        int gapStart = -1;
        for (int i = from; i < to; i++) {
            bool skipped = false;
            foreach (var s in skip) if (i >= s[0] && i < s[1]) { skipped = true; break; }
            bool low = !skipped && Rms[i] < 0.3 * level;
            if (low && gapStart < 0) gapStart = i;
            if (!low && gapStart >= 0) { r.Add(new double[] { 0, gapStart, i - gapStart }); gapStart = -1; }
            if (!skipped && !low && Residual[i] > breakAt) r.Add(new double[] { 1, i, Residual[i] / (level * Math.Sqrt(2)) });
        }
        r.Add(new double[] { 9, level, noise });
        return r;
    }
}
'@

# Inside the VM: the steady tone and a player in the signed-in user's session (as in lab 013).
$guestSetup = {
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
public static class LabClock {
    [DllImport("kernel32.dll")] static extern void GetSystemTimePreciseAsFileTime(out long t);
    public static long UtcTicks() { long t; GetSystemTimePreciseAsFileTime(out t); return DateTime.FromFileTimeUtc(t).Ticks; }
    public static void Tone(string path, int seconds) {
        int rate = 48000, n = rate * seconds;
        using (var w = new BinaryWriter(File.Create(path))) {
            w.Write(0x46464952); w.Write(36 + n * 4); w.Write(0x45564157); w.Write(0x20746D66); w.Write(16);
            w.Write((short)1); w.Write((short)2); w.Write(rate); w.Write(rate * 4); w.Write((short)4); w.Write((short)16);
            w.Write(0x61746164); w.Write(n * 4);
            // 440 whole cycles per second: the loop is seamless.
            for (int i = 0; i < n; i++) { short s = (short)(0.4 * Math.Sin(2 * Math.PI * 440 * i / rate) * 32767); w.Write(s); w.Write(s); }
        }
    }
}
"@
}
$dir = 'C:\GpuVM\lab014'
$session = New-PSSession -VMName $Name -Credential $guest
Invoke-Command -Session $session -ArgumentList $guestSetup, $dir -ScriptBlock {
    param($setup, $dir)
    . ([scriptblock]::Create($setup))
    New-Item -ItemType Directory -Force $dir | Out-Null
    [LabClock]::Tone("$dir\tone.wav", 60)
    Set-Content "$dir\play.ps1" -Encoding UTF8 -Value @'
param([string]$Wav, [int]$Seconds)
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class C { [DllImport("kernel32.dll")] static extern void GetSystemTimePreciseAsFileTime(out long t); public static long Now() { long t; GetSystemTimePreciseAsFileTime(out t); return DateTime.FromFileTimeUtc(t).Ticks; } }'
$p = New-Object Media.SoundPlayer $Wav
$p.Load()
$start = [C]::Now()
$p.PlayLooping(); Start-Sleep -Seconds $Seconds; $p.Stop()
Set-Content (Join-Path (Split-Path $Wav) 'start.txt') $start
'@
}

function Set-Sink {
    param([string]$Sink)
    Invoke-Command -Session $session -ArgumentList $streamingCode, $Sink -ScriptBlock {
        param($code, $sink)
        . ([scriptblock]::Create($code))
        Set-SunshineConfig -Path (Join-Path $env:ProgramFiles 'Sunshine\config\sunshine.conf') -Settings ([ordered]@{ virtual_sink = $sink })
        Restart-GpuVMSunshine
    }
    Start-Sleep -Seconds 5
    & $module { param($a, $c) Wait-SunshineReady -Address $a -Credential $c -TimeoutSec 120 } $endpoint.Address $sunshine
    Get-Process moonlight -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    & $module { param($f, $a) Start-UnelevatedProcess -FilePath $f -ArgumentList $a } $moonlight $arguments | Out-Null
    Start-Sleep -Seconds 15
}
# VM clock minus this PC's clock, from the round trip with the shortest time.
function Measure-ClockOffset {
    $best = $null
    for ($i = 0; $i -lt 30; $i++) {
        $t0 = [DateTime]::UtcNow.Ticks
        $vm = Invoke-Command -Session $session { [LabClock]::UtcTicks() }
        $t1 = [DateTime]::UtcNow.Ticks
        if (-not $best -or ($t1 - $t0) -lt $best.rtt) { $best = @{ rtt = $t1 - $t0; offset = $vm - ($t0 + $t1) / 2 } }
    }
    $best
}

$original = Invoke-Command -Session $session { (Get-Content 'C:\Program Files\Sunshine\config\sunshine.conf' | Select-String '^\s*virtual_sink\s*=\s*(.+)$').Matches[0].Groups[1].Value.Trim() }
$outputs = Invoke-Command -Session $session { Get-PnpDevice -Class AudioEndpoint -PresentOnly | Where-Object { $_.InstanceId -like 'SWD\MMDEVAPI\{0.0.0.*' -and $_.Status -eq 'OK' } | ForEach-Object FriendlyName }
$sinks = @(@{ sink = @($outputs | Where-Object { $_ -like '*GpuVM Audio*' })[0]; minutes = $Minutes })
$steam = @($outputs | Where-Object { $_ -like '*Steam Streaming Speakers*' })[0]
if ($steam) { $sinks += @{ sink = $steam; minutes = $ControlMinutes } }
if (-not $sinks[0].sink) { throw 'La VM no tiene la salida GpuVM Audio.' }

try {
    foreach ($s in $sinks) {
        Write-Host "`n== $($s.sink)" -ForegroundColor Cyan
        Set-Sink $s.sink
        $isSpeaker = $s.sink -like '*GpuVM Audio*'
        $logStart = Invoke-Command -Session $session { @(Get-Content 'C:\ProgramData\GpuVM\Audio\server.log' -ErrorAction SilentlyContinue).Count }
        $clock = Measure-ClockOffset
        $seconds = $s.minutes * 60
        [OutputRecorder]::Start()
        Invoke-Command -Session $session -ArgumentList $dir, $seconds -ScriptBlock {
            param($dir, $seconds)
            Remove-Item "$dir\start.txt" -ErrorAction SilentlyContinue
            $user = (Get-CimInstance Win32_ComputerSystem).UserName
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\play.ps1`" -Wav `"$dir\tone.wav`" -Seconds $seconds"
            Register-ScheduledTask -TaskName 'GpuVM-Lab014-Play' -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive) -Force | Out-Null
            Start-ScheduledTask -TaskName 'GpuVM-Lab014-Play'
        }
        $deadline = (Get-Date).AddSeconds($seconds + 120)
        do {
            Start-Sleep -Seconds 2
            $start = Invoke-Command -Session $session -ArgumentList $dir -ScriptBlock { param($d) Get-Content "$d\start.txt" -ErrorAction SilentlyContinue }
        } while (-not $start -and (Get-Date) -lt $deadline)
        [OutputRecorder]::Stop()
        Invoke-Command -Session $session { Unregister-ScheduledTask -TaskName 'GpuVM-Lab014-Play' -Confirm:$false -ErrorAction SilentlyContinue }
        if (-not $start) { throw 'La VM no informó cuándo empezó a sonar.' }
        if ([OutputRecorder]::Error) { throw "Grabación: $([OutputRecorder]::Error)" }
        $start = [long]"$start".Trim()

        # VM time -> window index in the recording: VM time - offset = this PC's time; + latency = when it is heard.
        $toWindow = { param([long]$vmTicks) [int][math]::Floor(($vmTicks - $clock.offset + $LatencyMs * 1e4 - [OutputRecorder]::StartTicks) / 1e4) }
        $first = (& $toWindow $start) + 1000
        $last = [math]::Min((& $toWindow ($start + $seconds * 1e7)) - 1000, [OutputRecorder]::Rms.Count)
        # ±300 ms around each loop of the 60 s file.
        $skip = New-Object 'System.Collections.Generic.List[int[]]'
        for ($k = 1; $k * 60 -lt $seconds; $k++) { $w = & $toWindow ($start + $k * 6e8); $skip.Add([int[]]@(($w - 300), ($w + 300))) }
        $events = [OutputRecorder]::Events($first, $last, $skip)
        $summary = $events[$events.Count - 1]
        $gaps = @($events | Where-Object { $_[0] -eq 0 })
        $breaks = @($events | Where-Object { $_[0] -eq 1 })

        $run = [ordered]@{
            sink = $s.sink; minutes = [math]::Round(($last - $first) / 60000, 2)
            rate = [OutputRecorder]::Rate; captureDiscontinuities = [OutputRecorder]::Discontinuities
            level = [math]::Round($summary[1], 4); codingNoise = [math]::Round($summary[2], 5)
            gaps = $gaps.Count; gapMs = @($gaps | ForEach-Object { $_[2] })
            breaks = $breaks.Count; breakSize = @($breaks | ForEach-Object { [math]::Round($_[2], 2) })
        }
        if ($isSpeaker) {
            $lines = Invoke-Command -Session $session -ArgumentList $logStart -ScriptBlock { param($n) Get-Content 'C:\ProgramData\GpuVM\Audio\server.log' | Select-Object -Skip $n }
            $underruns = @(foreach ($line in $lines) {
                if ($line -match 'underrun ([\d.]+) ms at (\S+)') {
                    $t = [DateTime]::Parse($Matches[2], [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime().Ticks
                    [pscustomobject]@{ ms = [double]$Matches[1]; window = & $toWindow $t }
                }
            })
            $inside = @($underruns | Where-Object { $_.window -ge $first -and $_.window -lt $last })
            # An event within 150 ms of an underrun's expected arrival counts as heard (latency varies by a few ms
            # and the speaker logs when the late transfer arrives, not when its gap started).
            $heard = @($inside | Where-Object { $u = $_; @($events | Where-Object { $_[0] -lt 9 -and [math]::Abs($_[1] - $u.window) -le 150 }).Count })
            $run.underruns = $inside.Count
            $run.underrunMs = @($inside | ForEach-Object ms)
            $run.underrunsHeard = $heard.Count
            $run.eventsWithoutUnderrun = @($events | Where-Object { $e = $_; $e[0] -lt 9 -and -not @($inside | Where-Object { [math]::Abs($e[1] - $_.window) -le 150 }).Count }).Count
        }
        $run | Format-List | Out-Host
        $report.runs += $run
    }
}
catch { $report.error = "$($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)"; Write-Warning $report.error }
finally {
    try { [OutputRecorder]::Stop() } catch { }
    try {
        Invoke-Command -Session $session { Unregister-ScheduledTask -TaskName 'GpuVM-Lab014-Play' -Confirm:$false -ErrorAction SilentlyContinue }
        if ($original) { Set-Sink $original }
        $report.restoredSink = $original
    }
    catch { $report.restoreError = "$_" }
    Remove-PSSession $session -ErrorAction SilentlyContinue
    $report.finishedAt = (Get-Date).ToString('o')
    New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
    $report | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 $OutFile
    Write-Host "`nResultado: $OutFile" -ForegroundColor Green
}
