# Lab 015: does completing each transfer a few milliseconds early remove the speaker's audible underruns (lab 014)
# without adding latency? No questions asked; results go to out\lab-*.json and the speaker is left as installed.
# For each lead (milliseconds each transfer is completed before its time; 0 is what labs 013 and 014 measured), with
# GpuVM's speaker as Sunshine's sink, this PC records its own output by WASAPI loopback (keep everything else on this
# PC silent) and the lab measures, on that recording:
#   1. Latency: the VM plays a 100 ms, 1 kHz burst every second for 30 s; each burst's first 1 ms window above 30 %
#      of the bursts' level, minus the moment the VM played it (clocks aligned through PowerShell Direct).
#   2. Clicks: the VM plays a steady 440 Hz tone for -Minutes; gaps and breaks in the wave as in lab 014, plus the
#      speaker's underruns and the audio it keeps queued.
# Elevated, PowerShell 7: pwsh -File labs\015-early-completion\lab.ps1 [-Leads 0,5] [-Minutes 10]
param(
    [string]$Name = (Get-VM | Where-Object Notes -like "Creada con GpuVM*" | Select-Object -First 1).Name,
    [double[]]$Leads = @(0, 5),
    [int]$Minutes = 10,
    [string]$OutFile = (Join-Path $PSScriptRoot "out\lab-$(Get-Date -Format yyyyMMdd-HHmmss).json")
)
$ErrorActionPreference = 'Stop'
$repo = Join-Path $PSScriptRoot '..\..'
Import-Module (Join-Path $repo 'src\GpuVM\GpuVM.psd1') -Force
$module = Get-Module GpuVM
$report = [ordered]@{ vm = $Name; startedAt = (Get-Date).ToString('o'); minutes = $Minutes; runs = @() }

# Opened the way the app does it: this also installs or updates the speaker.
Connect-GpuVM -Name $Name
$state = & $module { param($n) Get-GpuVMState -Name $n } $Name
$guest = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state
$sunshine = & $module { param($s) Get-SunshineCredential -State $s } $state
$endpoint = & $module { param($n) Get-GpuVMEndpoint -Name $n -TimeoutSec 60 } $Name
$moonlight = & $module { Get-MoonlightPath }
$arguments = & $module { param($a, $c) Get-MoonlightStreamArguments -Address $a -Client $c } $endpoint.Address $state['config']['streaming']['client']
$streamingCode = Get-Content -Raw (Join-Path $repo 'guest\streaming.ps1')

# The recorder of lab 014: this PC's output in 1 ms windows (level and sine predictor error).
$lab014 = Get-Content -Raw (Join-Path $PSScriptRoot '..\014-audible-underruns\lab.ps1')
Add-Type -TypeDefinition ([regex]::Match($lab014, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@").Groups[1].Value)

# Inside the VM: a precise clock and the two test sounds.
$guestSetup = {
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
public static class LabClock {
    [DllImport("kernel32.dll")] static extern void GetSystemTimePreciseAsFileTime(out long t);
    public static long UtcTicks() { long t; GetSystemTimePreciseAsFileTime(out t); return DateTime.FromFileTimeUtc(t).Ticks; }
    // 48 kHz 16-bit stereo. bursts: 100 ms of 1 kHz at every whole second from 1 s on; otherwise a steady 440 Hz tone.
    public static void Wav(string path, int seconds, bool bursts) {
        int rate = 48000, n = rate * seconds;
        using (var w = new BinaryWriter(File.Create(path))) {
            w.Write(0x46464952); w.Write(36 + n * 4); w.Write(0x45564157); w.Write(0x20746D66); w.Write(16);
            w.Write((short)1); w.Write((short)2); w.Write(rate); w.Write(rate * 4); w.Write((short)4); w.Write((short)16);
            w.Write(0x61746164); w.Write(n * 4);
            for (int i = 0; i < n; i++) {
                double t = (double)i / rate, v;
                if (bursts) v = (i >= rate && i % rate < rate / 10) ? 0.5 * Math.Sin(2 * Math.PI * 1000 * t) : 0;
                else v = 0.4 * Math.Sin(2 * Math.PI * 440 * t);
                short s = (short)(v * 32767); w.Write(s); w.Write(s);
            }
        }
    }
}
"@
}
$dir = 'C:\GpuVM\lab015'
$session = New-PSSession -VMName $Name -Credential $guest
Invoke-Command -Session $session -ArgumentList $guestSetup, $dir -ScriptBlock {
    param($setup, $dir)
    . ([scriptblock]::Create($setup))
    New-Item -ItemType Directory -Force $dir | Out-Null
    [LabClock]::Wav("$dir\bursts.wav", 31, $true)
    [LabClock]::Wav("$dir\tone.wav", 60, $false)
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

# Restarts the speaker's server with a given lead (or the installed arguments with $null) and attaches it again.
function Set-Lead {
    param($Lead)
    Invoke-Command -Session $session -ArgumentList $streamingCode, $Lead -ScriptBlock {
        param($code, $lead)
        . ([scriptblock]::Create($code))
        if ($null -ne $lead) { $script:AudioLeadMs = $lead }
        $task = Get-ScheduledTask -TaskName $script:AudioTask
        $action = $task.Actions[0]; $action.Arguments = Get-GpuVMAudioArguments
        Set-ScheduledTask -TaskName $script:AudioTask -Action $action | Out-Null
        Stop-ScheduledTask -TaskName $script:AudioTask -ErrorAction SilentlyContinue
        Get-Process GpuVMAudio -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 2
        Start-ScheduledTask -TaskName $script:AudioTask
        Connect-GpuVMAudioDevice -Usbip (Get-GpuVMUsbipPath)
        if (-not (Wait-GpuVMAudioEndpoint -Seconds 60)) { throw 'La salida GpuVM Audio no volvió.' }
    }
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
# Plays a file in the signed-in user's session while this PC records; returns the VM time it started.
function Invoke-Recorded {
    param([string]$Wav, [int]$Seconds)
    [OutputRecorder]::Start()
    Invoke-Command -Session $session -ArgumentList $dir, $Wav, $Seconds -ScriptBlock {
        param($dir, $wav, $seconds)
        Remove-Item "$dir\start.txt" -ErrorAction SilentlyContinue
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\play.ps1`" -Wav `"$dir\$wav`" -Seconds $seconds"
        Register-ScheduledTask -TaskName 'GpuVM-Lab015-Play' -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive) -Force | Out-Null
        Start-ScheduledTask -TaskName 'GpuVM-Lab015-Play'
    }
    $deadline = (Get-Date).AddSeconds([math]::Max($Seconds, 31) + 120)
    do {
        Start-Sleep -Seconds 2
        $start = Invoke-Command -Session $session -ArgumentList $dir -ScriptBlock { param($d) Get-Content "$d\start.txt" -ErrorAction SilentlyContinue }
    } while (-not $start -and (Get-Date) -lt $deadline)
    [OutputRecorder]::Stop()
    # Loopback only delivers what is played; if the output stopped, windows no longer match milliseconds.
    $script:timelineGapMs = [math]::Round(([DateTime]::UtcNow.Ticks - [OutputRecorder]::StartTicks) / 1e4 - [OutputRecorder]::Rms.Count)
    Invoke-Command -Session $session { Unregister-ScheduledTask -TaskName 'GpuVM-Lab015-Play' -Confirm:$false -ErrorAction SilentlyContinue }
    if (-not $start) { throw 'La VM no informó cuándo empezó a sonar.' }
    if ([OutputRecorder]::Error) { throw "Grabación: $([OutputRecorder]::Error)" }
    [long]"$start".Trim()
}
function Get-ServerStatus {
    Invoke-Command -Session $session { Get-Content 'C:\ProgramData\GpuVM\Audio\status.json' -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json }
}
function Get-Percentile([double[]]$Values, [double]$P) {
    $sorted = @($Values | Sort-Object)
    if (-not $sorted) { return $null }
    $sorted[[math]::Min($sorted.Count - 1, [math]::Floor($P * ($sorted.Count - 1)))]
}

$sink = Invoke-Command -Session $session { Get-PnpDevice -Class AudioEndpoint -PresentOnly | Where-Object { $_.InstanceId -like 'SWD\MMDEVAPI\{0.0.0.*' -and $_.FriendlyName -like '*GpuVM Audio*' -and $_.Status -eq 'OK' } | Select-Object -First 1 -ExpandProperty FriendlyName }
if (-not $sink) { throw 'La VM no tiene la salida GpuVM Audio.' }

try {
    foreach ($lead in $Leads) {
        Write-Host "`n== lead $lead ms" -ForegroundColor Cyan
        Set-Lead $lead
        Set-Sink $sink
        $run = [ordered]@{ leadMs = $lead; serverLead = (Get-ServerStatus).leadMs }

        # 1. Latency, from the recording: VM time - offset = this PC's time; window i is millisecond i.
        $clock = Measure-ClockOffset
        $start = Invoke-Recorded -Wav 'bursts.wav' -Seconds 0
        $toWindow = { param([long]$vmTicks) [int][math]::Floor(($vmTicks - $clock.offset - [OutputRecorder]::StartTicks) / 1e4) }
        $rms = [OutputRecorder]::Rms.ToArray()
        $level = ($rms | Measure-Object -Maximum).Maximum
        $latencies = foreach ($k in 1..30) {
            $expected = & $toWindow ($start + $k * 1e7)
            for ($i = [math]::Max(1, $expected - 20); $i -lt [math]::Min($rms.Count, $expected + 600); $i++) {
                if ($rms[$i] -ge 0.3 * $level -and $rms[$i - 1] -lt 0.3 * $level) { $i - $expected; break }
            }
        }
        $run.latency = [ordered]@{
            detected = @($latencies).Count; medianMs = Get-Percentile $latencies 0.5; p90Ms = Get-Percentile $latencies 0.9
            minMs = ($latencies | Measure-Object -Minimum).Minimum; maxMs = ($latencies | Measure-Object -Maximum).Maximum
            clockErrorMs = [math]::Round($clock.rtt / 2e4, 2)
        }

        # 2. Clicks over a long session.
        $before = Get-ServerStatus
        $clock = Measure-ClockOffset
        $seconds = $Minutes * 60
        $start = Invoke-Recorded -Wav 'tone.wav' -Seconds $seconds
        $after = Get-ServerStatus
        $lag = if ($run.latency.medianMs) { $run.latency.medianMs } else { 63 }
        $toHeard = { param([long]$vmTicks) [int][math]::Floor(($vmTicks - $clock.offset - [OutputRecorder]::StartTicks) / 1e4 + $lag) }
        $first = (& $toHeard $start) + 1000
        $last = [math]::Min((& $toHeard ($start + $seconds * 1e7)) - 1000, [OutputRecorder]::Rms.Count)
        $skip = New-Object 'System.Collections.Generic.List[int[]]'
        for ($k = 1; $k * 60 -lt $seconds; $k++) { $w = & $toHeard ($start + $k * 6e8); $skip.Add([int[]]@(($w - 300), ($w + 300))) }
        $events = [OutputRecorder]::Events($first, $last, $skip)
        $summary = $events[$events.Count - 1]
        $gaps = @($events | Where-Object { $_[0] -eq 0 })
        $breaks = @($events | Where-Object { $_[0] -eq 1 })
        $samples = $after.aheadSamples - $before.aheadSamples
        $run.clicks = [ordered]@{
            minutes = [math]::Round(($last - $first) / 60000, 2); level = [math]::Round($summary[1], 4); codingNoise = [math]::Round($summary[2], 5)
            gaps = $gaps.Count; gapMs = @($gaps | ForEach-Object { $_[2] }); breaks = $breaks.Count
            underruns = $after.underruns - $before.underruns; underrunMs = [math]::Round($after.underrunMs - $before.underrunMs, 1)
            queuedAvgMs = if ($samples) { [math]::Round(($after.aheadSumMs - $before.aheadSumMs) / $samples, 1) } else { $null }
            transfers = $after.urbs - $before.urbs; unlinks = $after.unlinks - $before.unlinks
            recordingShortByMs = $script:timelineGapMs
        }
        $run.latency | Format-List | Out-Host
        $run.clicks | Format-List | Out-Host
        $report.runs += $run
    }
}
catch { $report.error = "$($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)"; Write-Warning $report.error }
finally {
    try { [OutputRecorder]::Stop() } catch { }
    try {
        Invoke-Command -Session $session { Unregister-ScheduledTask -TaskName 'GpuVM-Lab015-Play' -Confirm:$false -ErrorAction SilentlyContinue }
        # Back to the installed arguments, then Sunshine and Moonlight on the speaker again.
        Set-Lead $null
        Set-Sink $sink
        $report.restored = $true
    }
    catch { $report.restoreError = "$_" }
    Remove-PSSession $session -ErrorAction SilentlyContinue
    $report.finishedAt = (Get-Date).ToString('o')
    New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
    $report | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 $OutFile
    Write-Host "`nResultado: $OutFile" -ForegroundColor Green
}
