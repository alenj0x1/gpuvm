# Lab 013: how late and how clean is the VM's sound through GpuVM's USB speaker, over a long session?
# No questions asked; results go to out\lab-*.json and the VM is left with the speaker as Sunshine's sink.
# For each sink (GpuVM's speaker, then Steam Streaming Speakers as the control when the VM has it):
#   1. Latency: the VM plays a 1 kHz burst every second for 30 s; this PC records the peak of Moonlight's own audio
#      session every 2 ms and times each burst against the moment the VM started playing (clocks aligned through
#      PowerShell Direct, the round trip bounds the error).
#   2. Dropouts: the VM plays a steady 440 Hz tone for -Minutes; every stretch of 15 ms or more where Moonlight's
#      level falls under 30 % of the tone is a dropout. The speaker's own counters (underruns, queued audio) are read
#      before and after.
# Elevated, PowerShell 7: pwsh -File labs\013-audio-latency-and-dropouts\lab.ps1 [-Minutes 10] [-ControlMinutes 3]
param(
    [string]$Name = (Get-VM | Where-Object Notes -like "Creada con GpuVM*" | Select-Object -First 1).Name,
    [int]$Minutes = 10,
    [int]$ControlMinutes = 3,
    [string]$OutFile = (Join-Path $PSScriptRoot "out\lab-$(Get-Date -Format yyyyMMdd-HHmmss).json")
)
$ErrorActionPreference = 'Stop'
$repo = Join-Path $PSScriptRoot '..\..'
Import-Module (Join-Path $repo 'src\GpuVM\GpuVM.psd1') -Force
$module = Get-Module GpuVM
$report = [ordered]@{ vm = $Name; startedAt = (Get-Date).ToString('o'); minutes = $Minutes; controlMinutes = $ControlMinutes; runs = @() }

# Opened the way the app does it: this also installs or updates the speaker.
Connect-GpuVM -Name $Name
$state = & $module { param($n) Get-GpuVMState -Name $n } $Name
$guest = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state
$sunshine = & $module { param($s) Get-SunshineCredential -State $s } $state
$endpoint = & $module { param($n) Get-GpuVMEndpoint -Name $n -TimeoutSec 60 } $Name
$moonlight = & $module { Get-MoonlightPath }
$arguments = & $module { param($a, $c) Get-MoonlightStreamArguments -Address $a -Client $c } $endpoint.Address $state['config']['streaming']['client']
$streamingCode = Get-Content -Raw (Join-Path $repo 'guest\streaming.ps1')

# This PC: Moonlight's audio sessions on the default output, sampled on a background thread.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
public static class MoonlightMeter {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class En {}
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator { int NotImpl1(); int GetDefaultAudioEndpoint(int f, int r, out IMMDevice d); }
    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice { int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); }
    [Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2 { int NotImpl1(); int NotImpl2(); int GetSessionEnumerator(out IAudioSessionEnumerator e); }
    [Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator { int GetCount(out int c); int GetSession(int i, out IAudioSessionControl2 s); }
    [Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2 {
        int GetState(out int s); int GetDisplayName(out IntPtr n); int SetDisplayName(string n, Guid g); int GetIconPath(out IntPtr p);
        int SetIconPath(string p, Guid g); int GetGroupingParam(out Guid g); int SetGroupingParam(Guid g, Guid c);
        int RegisterAudioSessionNotification(IntPtr n); int UnregisterAudioSessionNotification(IntPtr n);
        int GetSessionIdentifier(out IntPtr s); int GetSessionInstanceIdentifier(out IntPtr s); int GetProcessId(out uint pid);
    }
    [Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation { int GetPeakValue(out float peak); }
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint p);

    static Thread thread;
    static volatile bool running;
    public static List<long> Ticks = new List<long>();
    public static List<float> Peaks = new List<float>();

    // Starts sampling the sessions of the given processes; returns how many sessions it found.
    public static int Start(int[] pids, int intervalMs) {
        var e = (IMMDeviceEnumerator)new En();
        IMMDevice d; e.GetDefaultAudioEndpoint(0, 0, out d);
        var iid = typeof(IAudioSessionManager2).GUID; object o; d.Activate(ref iid, 23, IntPtr.Zero, out o);
        IAudioSessionEnumerator se; ((IAudioSessionManager2)o).GetSessionEnumerator(out se);
        int n; se.GetCount(out n);
        var meters = new List<IAudioMeterInformation>();
        for (int i = 0; i < n; i++) {
            IAudioSessionControl2 s; se.GetSession(i, out s); uint pid; s.GetProcessId(out pid);
            if (Array.IndexOf(pids, (int)pid) >= 0) meters.Add((IAudioMeterInformation)s);
        }
        Ticks = new List<long>(); Peaks = new List<float>();
        timeBeginPeriod(1);
        running = true;
        thread = new Thread(() => {
            while (running) {
                float peak = 0;
                foreach (var m in meters) { float p; m.GetPeakValue(out p); if (p > peak) peak = p; }
                Ticks.Add(DateTime.UtcNow.Ticks); Peaks.Add(peak);
                Thread.Sleep(intervalMs);
            }
        });
        thread.IsBackground = true; thread.Start();
        return meters.Count;
    }
    public static void Stop() { running = false; if (thread != null) thread.Join(); }
}
'@

# Inside the VM: a precise clock (Windows PowerShell's DateTime.UtcNow ticks in ~1-15 ms steps) and the test sounds.
$guestSetup = {
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
public static class LabClock {
    [DllImport("kernel32.dll")] static extern void GetSystemTimePreciseAsFileTime(out long t);
    public static long UtcTicks() { long t; GetSystemTimePreciseAsFileTime(out t); return DateTime.FromFileTimeUtc(t).Ticks; }
    // 48 kHz 16-bit stereo. bursts: 100 ms of 1 kHz at every whole second from 1 s on; otherwise a steady tone.
    public static void Wav(string path, int seconds, bool bursts) {
        int rate = 48000, n = rate * seconds;
        using (var w = new BinaryWriter(File.Create(path))) {
            w.Write(0x46464952); w.Write(36 + n * 4); w.Write(0x45564157); w.Write(0x20746D66); w.Write(16);
            w.Write((short)1); w.Write((short)2); w.Write(rate); w.Write(rate * 4); w.Write((short)4); w.Write((short)16);
            w.Write(0x61746164); w.Write(n * 4);
            for (int i = 0; i < n; i++) {
                double t = (double)i / rate, v;
                if (bursts) v = (i >= rate && i % rate < rate / 10) ? 0.5 * Math.Sin(2 * Math.PI * 1000 * t) : 0;
                else v = 0.4 * Math.Sin(2 * Math.PI * 440 * t); // 440 whole cycles per second: the loop is seamless
                short s = (short)(v * 32767); w.Write(s); w.Write(s);
            }
        }
    }
}
"@
}
$dir = 'C:\GpuVM\lab013'
$session = New-PSSession -VMName $Name -Credential $guest
Invoke-Command -Session $session -ArgumentList $guestSetup, $dir -ScriptBlock {
    param($setup, $dir)
    . ([scriptblock]::Create($setup))
    New-Item -ItemType Directory -Force $dir | Out-Null
    [LabClock]::Wav("$dir\bursts.wav", 31, $true)
    [LabClock]::Wav("$dir\tone.wav", 60, $false)
    # Played in the signed-in user's session, like a game; writes the precise moment playback was asked for.
    Set-Content "$dir\play.ps1" -Encoding UTF8 -Value @'
param([string]$Wav, [int]$Seconds)
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class C { [DllImport("kernel32.dll")] static extern void GetSystemTimePreciseAsFileTime(out long t); public static long Now() { long t; GetSystemTimePreciseAsFileTime(out t); return DateTime.FromFileTimeUtc(t).Ticks; } }'
$p = New-Object Media.SoundPlayer $Wav
$p.Load()
$start = [C]::Now()
if ($Seconds -gt 0) { $p.PlayLooping(); Start-Sleep -Seconds $Seconds; $p.Stop() } else { $p.PlaySync() }
Set-Content (Join-Path (Split-Path $Wav) 'start.txt') $start
'@
}

function Invoke-GuestPlay {
    param([string]$Wav, [int]$Seconds)
    Invoke-Command -Session $session -ArgumentList $dir, $Wav, $Seconds -ScriptBlock {
        param($dir, $wav, $seconds)
        Remove-Item "$dir\start.txt" -ErrorAction SilentlyContinue
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\play.ps1`" -Wav `"$dir\$wav`" -Seconds $seconds"
        Register-ScheduledTask -TaskName 'GpuVM-Lab013-Play' -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive) -Force | Out-Null
        Start-ScheduledTask -TaskName 'GpuVM-Lab013-Play'
    }
}
function Get-GuestPlayStart {
    param([int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $t = Invoke-Command -Session $session -ArgumentList $dir -ScriptBlock { param($d) Get-Content "$d\start.txt" -ErrorAction SilentlyContinue }
        if ($t) { break }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    Invoke-Command -Session $session { Unregister-ScheduledTask -TaskName 'GpuVM-Lab013-Play' -Confirm:$false -ErrorAction SilentlyContinue }
    if (-not $t) { throw 'La VM no informó cuándo empezó a sonar.' }
    [long]"$t".Trim()
}
# VM clock minus this PC's clock, from the round trip with the shortest time (its half is the error bound).
function Measure-ClockOffset {
    $best = $null
    for ($i = 0; $i -lt 30; $i++) {
        $t0 = [DateTime]::UtcNow.Ticks
        $vm = Invoke-Command -Session $session { [LabClock]::UtcTicks() }
        $t1 = [DateTime]::UtcNow.Ticks
        if (-not $best -or ($t1 - $t0) -lt $best.rtt) { $best = @{ rtt = $t1 - $t0; offset = $vm - ($t0 + $t1) / 2 } }
    }
    [pscustomobject]@{ offsetMs = [math]::Round($best.offset / 1e4, 2); errorMs = [math]::Round($best.rtt / 2e4, 2); offsetTicks = $best.offset }
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
function Start-Meter {
    $pids = @(Get-Process moonlight -ErrorAction SilentlyContinue | ForEach-Object Id)
    $found = [MoonlightMeter]::Start([int[]]$pids, 2)
    if (-not $found) { throw 'Moonlight no tiene una sesión de audio en la salida predeterminada de este equipo.' }
}
function Get-ServerStatus {
    Invoke-Command -Session $session { Get-Content 'C:\ProgramData\GpuVM\Audio\status.json' -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json }
}
function Get-Percentile([double[]]$Values, [double]$P) {
    $sorted = @($Values | Sort-Object)
    if (-not $sorted) { return $null }
    $sorted[[math]::Min($sorted.Count - 1, [math]::Floor($P * ($sorted.Count - 1)))]
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
        $run = [ordered]@{ sink = $s.sink }

        # 1. Latency. If Moonlight did not connect (no burst arrives at all), it is reopened once.
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $clockBefore = Measure-ClockOffset
            Start-Meter
            Invoke-GuestPlay -Wav 'bursts.wav' -Seconds 0
            $start = Get-GuestPlayStart -TimeoutSec 60
            [MoonlightMeter]::Stop()
            $clockAfter = Measure-ClockOffset
            $offset = ($clockBefore.offsetTicks + $clockAfter.offsetTicks) / 2
            $ticks = [MoonlightMeter]::Ticks.ToArray(); $peaks = [MoonlightMeter]::Peaks.ToArray()
            $max = ($peaks | Measure-Object -Maximum).Maximum
            $threshold = [math]::Max(0.25 * $max, 0.02)
            $latencies = foreach ($k in 1..30) {
                $expected = $start + $k * 1e7 - $offset
                for ($i = 1; $i -lt $ticks.Count; $i++) {
                    if ($ticks[$i] -lt $expected - 2e5) { continue }
                    if ($ticks[$i] -gt $expected + 6e6) { break }
                    if ($peaks[$i] -ge $threshold -and $peaks[$i - 1] -lt $threshold) { [math]::Round(($ticks[$i] - $expected) / 1e4, 1); break }
                }
            }
            $run.latency = [ordered]@{
                bursts = 30; detected = @($latencies).Count
                medianMs = Get-Percentile $latencies 0.5; p90Ms = Get-Percentile $latencies 0.9
                minMs = ($latencies | Measure-Object -Minimum).Minimum; maxMs = ($latencies | Measure-Object -Maximum).Maximum
                clockErrorMs = [math]::Max($clockBefore.errorMs, $clockAfter.errorMs); clockDriftMs = [math]::Round(($clockAfter.offsetTicks - $clockBefore.offsetTicks) / 1e4, 2)
                meterPeak = [math]::Round($max, 3); samples = $ticks.Count; attempt = $attempt
            }
            if (@($latencies).Count -or $attempt -eq 2) { break }
            Write-Warning 'No llegó ninguna ráfaga a Moonlight; se vuelve a abrir.'
            Set-Sink $s.sink
        }
        $run.latency | Format-List | Out-Host

        # 2. Dropouts over a long session.
        $serverBefore = Get-ServerStatus
        $clock = Measure-ClockOffset
        Start-Meter
        $seconds = $s.minutes * 60
        Invoke-GuestPlay -Wav 'tone.wav' -Seconds $seconds
        $start = Get-GuestPlayStart -TimeoutSec ($seconds + 120)
        [MoonlightMeter]::Stop()
        $serverAfter = Get-ServerStatus
        $ticks = [MoonlightMeter]::Ticks.ToArray(); $peaks = [MoonlightMeter]::Peaks.ToArray()
        # The tone reaches this PC about one latency after it starts; the first and last seconds and ±300 ms around
        # each 60 s loop of the file are left out.
        $lag = if ($run.latency.medianMs) { $run.latency.medianMs * 1e4 } else { 1e6 }
        $from = $start - $clock.offsetTicks + $lag + 1e7
        $to = $start - $clock.offsetTicks + $lag + ($seconds - 1) * 1e7
        $inside = @(for ($i = 0; $i -lt $ticks.Count; $i++) {
            if ($ticks[$i] -lt $from -or $ticks[$i] -gt $to) { continue }
            $sinceStart = ($ticks[$i] - ($start - $clock.offsetTicks + $lag)) % 6e8
            if ($sinceStart -lt 3e6 -or $sinceStart -gt 6e8 - 3e6) { continue }
            $i
        })
        $level = Get-Percentile ($inside | ForEach-Object { $peaks[$_] }) 0.5
        $low = 0.3 * $level
        $drops = New-Object System.Collections.Generic.List[double]
        $runStart = $null; $prev = $null
        foreach ($i in $inside) {
            $gap = $prev -ne $null -and ($i - $prev) -gt 1
            if ($runStart -ne $null -and ($peaks[$i] -ge $low -or $gap)) {
                $ms = ($ticks[$prev] - $ticks[$runStart]) / 1e4 + 2
                if ($ms -ge 15) { $drops.Add([math]::Round($ms, 1)) }
                $runStart = $null
            }
            if ($peaks[$i] -lt $low -and $runStart -eq $null) { $runStart = $i }
            $prev = $i
        }
        $measured = ($to - $from) / 6e8
        $run.dropouts = [ordered]@{
            minutes = [math]::Round($measured, 2); level = [math]::Round($level, 3); count = $drops.Count
            perMinute = if ($measured) { [math]::Round($drops.Count / $measured, 2) } else { $null }
            totalMs = [math]::Round(($drops | Measure-Object -Sum).Sum, 1); longestMs = ($drops | Measure-Object -Maximum).Maximum
            samples = $inside.Count
        }
        if ($s.sink -like '*GpuVM Audio*' -and $serverBefore -and $serverAfter) {
            $samples = $serverAfter.aheadSamples - $serverBefore.aheadSamples
            $run.speaker = [ordered]@{
                underruns = $serverAfter.underruns - $serverBefore.underruns
                underrunMs = [math]::Round($serverAfter.underrunMs - $serverBefore.underrunMs, 1)
                queuedAvgMs = if ($samples) { [math]::Round(($serverAfter.aheadSumMs - $serverBefore.aheadSumMs) / $samples, 1) } else { $null }
                queuedMaxMs = $serverAfter.aheadMaxMs
                transfers = $serverAfter.urbs - $serverBefore.urbs
                unlinks = $serverAfter.unlinks - $serverBefore.unlinks
            }
        }
        $run.dropouts | Format-List | Out-Host
        if ($run.speaker) { $run.speaker | Format-List | Out-Host }
        $report.runs += $run
    }
}
catch { $report.error = "$($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)"; Write-Warning $report.error }
finally {
    try { [MoonlightMeter]::Stop() } catch { }
    try {
        Invoke-Command -Session $session { Unregister-ScheduledTask -TaskName 'GpuVM-Lab013-Play' -Confirm:$false -ErrorAction SilentlyContinue }
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
