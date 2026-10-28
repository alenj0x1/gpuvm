# Lab 011, option A: does VB-CABLE carry the VM's sound when the output Sunshine captures accepts loopback?
# No questions asked; everything goes to out\lab-a-*.json and the VM is left as it was.
# 1. Inside the VM, for each VB-CABLE output: makes it the default, plays a sound and captures it by WASAPI
#    loopback with Sunshine's own flags (shared, float32 48 kHz stereo, AUTOCONVERTPCM).
# 2. End to end, for each output: virtual_sink = that output, Sunshine restarted, Moonlight reopened, and the peak
#    of Moonlight's own audio session on this PC, first with the VM silent and then with a sound playing.
# 3. Puts back virtual_sink and the default output and restarts Sunshine the way it was running.
# Elevated, PowerShell 7: pwsh -File labs\011-audio-without-steam\lab-a.ps1
param(
    [string]$Name = (Get-VM | Where-Object Notes -like "Creada con GpuVM*" | Select-Object -First 1).Name,
    [int]$Seconds = 5,
    # Outputs under test (lab 012 passes its own USB speaker).
    [string]$Match = '*VB-Audio Virtual Cable*',
    [switch]$SkipEndToEnd,
    [string]$OutFile = (Join-Path $PSScriptRoot "out\lab-a-$(Get-Date -Format yyyyMMdd-HHmmss).json")
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$module = Get-Module GpuVM
$report = [ordered]@{ vm = $Name; startedAt = (Get-Date).ToString('o'); startedVm = $false; loopback = $null; endToEnd = @(); restored = $null }

# Off: opened the way the app does it (network isolation, session, Sunshine ready), then left on.
if ((Get-VM -Name $Name).State -ne 'Running') {
    Connect-GpuVM -Name $Name
    $report.startedVm = $true
    Start-Sleep -Seconds 20
}

# Runs inside the VM (PowerShell Direct, session 0). Core Audio with [PreserveSig] so every HRESULT is reported.
$guestAudio = @'
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class LabAudio {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class En {}
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int f, int m, out IMMDeviceCollection c);
        [PreserveSig] int GetDefaultAudioEndpoint(int f, int r, out IMMDevice d);
    }
    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection { [PreserveSig] int GetCount(out int c); [PreserveSig] int Item(int i, out IMMDevice d); }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
        [PreserveSig] int OpenPropertyStore(int a, out IPropertyStore s);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    }
    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore { [PreserveSig] int GetCount(out int c); [PreserveSig] int GetAt(int i, out PropertyKey k); [PreserveSig] int GetValue(ref PropertyKey k, out PropVariant v); }
    [StructLayout(LayoutKind.Sequential)] struct PropertyKey { public Guid fmtid; public int pid; }
    [StructLayout(LayoutKind.Explicit)] struct PropVariant { [FieldOffset(0)] public short vt; [FieldOffset(8)] public IntPtr p; }
    [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")] class PolicyConfigCom {}
    [ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPolicyConfig {
        int GetMixFormat(); int GetDeviceFormat(); int ResetDeviceFormat(); int SetDeviceFormat(); int GetProcessingPeriod(); int SetProcessingPeriod();
        int GetShareMode(); int SetShareMode(); int GetPropertyValue(); int SetPropertyValue();
        [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
    }
    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation { [PreserveSig] int GetPeakValue(out float peak); }
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

    static List<IMMDevice> Outputs() {
        var e = (IMMDeviceEnumerator)new En(); IMMDeviceCollection col; e.EnumAudioEndpoints(0, 1, out col);
        int n; col.GetCount(out n); var list = new List<IMMDevice>();
        for (int i = 0; i < n; i++) { IMMDevice d; col.Item(i, out d); list.Add(d); }
        return list;
    }
    static string NameOf(IMMDevice d) {
        IPropertyStore ps; d.OpenPropertyStore(0, out ps);
        var key = new PropertyKey { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };
        PropVariant v; ps.GetValue(ref key, out v); return Marshal.PtrToStringUni(v.p);
    }
    static IMMDevice Find(string name) { foreach (var d in Outputs()) if (NameOf(d) == name) return d; return null; }
    static T Get<T>(IMMDevice d) { var iid = typeof(T).GUID; object o; Marshal.ThrowExceptionForHR(d.Activate(ref iid, 23, IntPtr.Zero, out o)); return (T)o; }

    public static List<string> Names() { var r = new List<string>(); foreach (var d in Outputs()) r.Add(NameOf(d)); return r; }
    public static string DefaultId() { var e = (IMMDeviceEnumerator)new En(); IMMDevice d; e.GetDefaultAudioEndpoint(0, 0, out d); string id; d.GetId(out id); return id; }
    public static string SetDefault(string name) {
        var d = Find(name); if (d == null) return null; string id; d.GetId(out id); SetDefaultById(id); return id;
    }
    public static void SetDefaultById(string id) { var pc = (IPolicyConfig)new PolicyConfigCom(); for (int role = 0; role < 3; role++) pc.SetDefaultEndpoint(id, role); }

    // Loopback of one output the way Sunshine opens it: shared mode, float32 48 kHz stereo, LOOPBACK | AUTOCONVERTPCM | SRC_DEFAULT_QUALITY.
    public static Dictionary<string, object> Capture(string name, int seconds) {
        var r = new Dictionary<string, object>(); r["name"] = name;
        var d = Find(name); if (d == null) { r["error"] = "not found"; return r; }
        var meter = Get<IAudioMeterInformation>(d);
        var ac = Get<IAudioClient>(d);
        IntPtr mix; ac.GetMixFormat(out mix);
        r["mixFormat"] = "tag=0x" + ((ushort)Marshal.ReadInt16(mix, 0)).ToString("X") + " ch=" + Marshal.ReadInt16(mix, 2) + " rate=" + Marshal.ReadInt32(mix, 4) + " bits=" + Marshal.ReadInt16(mix, 14);
        IntPtr fmt = Marshal.AllocHGlobal(40);
        try {
            byte[] f = new byte[40];
            BitConverter.GetBytes((ushort)0xFFFE).CopyTo(f, 0); BitConverter.GetBytes((short)2).CopyTo(f, 2);
            BitConverter.GetBytes(48000).CopyTo(f, 4); BitConverter.GetBytes(48000 * 8).CopyTo(f, 8);
            BitConverter.GetBytes((short)8).CopyTo(f, 12); BitConverter.GetBytes((short)32).CopyTo(f, 14);
            BitConverter.GetBytes((short)22).CopyTo(f, 16); BitConverter.GetBytes((short)32).CopyTo(f, 18);
            BitConverter.GetBytes(3).CopyTo(f, 20); new Guid("00000003-0000-0010-8000-00aa00389b71").ToByteArray().CopyTo(f, 24);
            Marshal.Copy(f, 0, fmt, 40);
            int hr = ac.Initialize(0, 0x00020000 | unchecked((int)0x80000000) | 0x08000000, 2000000, 0, fmt, IntPtr.Zero);
            r["initialize"] = "0x" + hr.ToString("X8");
            if (hr != 0) return r;
            var cid = typeof(IAudioCaptureClient).GUID; object co; Marshal.ThrowExceptionForHR(ac.GetService(ref cid, out co));
            var cc = (IAudioCaptureClient)co; ac.Start();
            long packets = 0, silent = 0, frames = 0; float peak = 0, meterPeak = 0;
            var end = DateTime.Now.AddSeconds(seconds);
            while (DateTime.Now < end) {
                float mp; meter.GetPeakValue(out mp); if (mp > meterPeak) meterPeak = mp;
                uint size; cc.GetNextPacketSize(out size);
                while (size > 0) {
                    IntPtr data; uint nf, flags; long p, q; cc.GetBuffer(out data, out nf, out flags, out p, out q);
                    packets++; frames += nf;
                    if ((flags & 2) != 0) silent++;
                    else { var buf = new float[nf * 2]; Marshal.Copy(data, buf, 0, buf.Length); foreach (var v in buf) { var a = Math.Abs(v); if (a > peak) peak = a; } }
                    cc.ReleaseBuffer(nf); cc.GetNextPacketSize(out size);
                }
                System.Threading.Thread.Sleep(10);
            }
            ac.Stop();
            r["packets"] = packets; r["silentPackets"] = silent; r["frames"] = frames;
            r["loopbackPeak"] = Math.Round(peak, 3); r["meterPeak"] = Math.Round(meterPeak, 3);
        } finally { Marshal.FreeHGlobal(fmt); }
        return r;
    }
}
"@
'@

# A sound in the signed-in user's session (what a game or video does). Started and stopped by the caller.
$playTask = {
    param([int]$Seconds)
    $user = (Get-CimInstance Win32_ComputerSystem).UserName
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -Command `$p=[Media.SoundPlayer]::new('C:\Windows\Media\Alarm01.wav');`$p.PlayLooping();Start-Sleep $Seconds"
    Register-ScheduledTask -TaskName 'GpuVM-Lab011-Play' -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive) -Force | Out-Null
}

# Sunshine as it runs today: service (ddx) or the user's logon task (wgc). Restarted the same way.
$restartSunshine = {
    param([string]$Sink)
    $conf = 'C:\Program Files\Sunshine\config\sunshine.conf'
    $lines = @(Get-Content -LiteralPath $conf | Where-Object { $_ -notmatch '^\s*virtual_sink\s*=' })
    if ($Sink) { $lines += "virtual_sink = $Sink" }
    [IO.File]::WriteAllLines($conf, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
    if (Get-ScheduledTask -TaskName 'GpuVM-Sunshine-User' -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName 'GpuVM-Sunshine-User' -ErrorAction SilentlyContinue
        Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-ScheduledTask -TaskName 'GpuVM-Sunshine-User'
    }
    else { Get-Service | Where-Object Name -like '*sunshine*' | Restart-Service -Force }
}

$state = & $module { param($n) Get-GpuVMState -Name $n } $Name
$guest = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state
$sunshine = & $module { param($s) Get-SunshineCredential -State $s } $state
$original = Invoke-Command -VMName $Name -Credential $guest -ArgumentList $guestAudio -ScriptBlock {
    param($code)
    . ([scriptblock]::Create($code))
    $sink = (Get-Content 'C:\Program Files\Sunshine\config\sunshine.conf' | Where-Object { $_ -match '^\s*virtual_sink\s*=' }) -replace '^\s*virtual_sink\s*=\s*', ''
    [pscustomobject]@{ sink = ([string]$sink).Trim(); defaultId = [LabAudio]::DefaultId(); outputs = @([LabAudio]::Names()) }
}
$report.original = $original | Select-Object sink, defaultId, outputs
$cables = @($original.outputs | Where-Object { $_ -like $Match })
if (-not $cables) { throw "La VM no tiene salidas que coincidan con '$Match'." }

try {
    # While streaming, Sunshine puts its sink back as the default whenever it changes: no stream during step 1.
    Get-Process moonlight -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 5
    # 1. Loopback inside the VM, each VB-CABLE output as the default while the sound plays.
    $report.loopback = @(Invoke-Command -VMName $Name -Credential $guest -ArgumentList $guestAudio, $playTask, $cables, $Seconds -ScriptBlock {
        param($code, $play, $cables, $seconds)
        . ([scriptblock]::Create($code))
        & ([scriptblock]::Create($play)) ($seconds + 4)
        $previous = [LabAudio]::DefaultId()
        try {
            foreach ($cable in $cables) {
                [LabAudio]::SetDefault($cable) | Out-Null
                Start-Sleep -Milliseconds 300
                Start-ScheduledTask -TaskName 'GpuVM-Lab011-Play'
                Start-Sleep -Milliseconds 1200
                try { $row = [LabAudio]::Capture($cable, $seconds) } catch { $row = @{ name = $cable; error = $_.Exception.Message } }
                $row['defaultWhileCapturing'] = [LabAudio]::DefaultId()
                Stop-ScheduledTask -TaskName 'GpuVM-Lab011-Play'
                Start-Sleep -Milliseconds 500
                $h = [ordered]@{}; foreach ($k in $row.Keys) { $h[$k] = $row[$k] }; [pscustomobject]$h
            }
        }
        finally {
            [LabAudio]::SetDefaultById($previous)
            Unregister-ScheduledTask -TaskName 'GpuVM-Lab011-Play' -Confirm:$false -ErrorAction SilentlyContinue
        }
    })
    $report.loopback | Format-Table name, initialize, packets, silentPackets, loopbackPeak, meterPeak -AutoSize | Out-Host

    # 2. End to end: Sunshine -> Moonlight -> this PC, one run per output.
    if (-not $SkipEndToEnd) {
        # The AudioSessions type from lab 010: every app playing on this PC's default output, with its peak.
        $sessions = Get-Content -Raw (Join-Path $PSScriptRoot '..\010-network-isolation\audio-sessions.ps1')
        Add-Type -TypeDefinition ([regex]::Match($sessions, "(?s)@'\r?\n(.*?)\r?\n'@").Groups[1].Value)
        $endpoint = & $module { param($n) Get-GpuVMEndpoint -Name $n -TimeoutSec 60 } $Name
        $moonlight = & $module { Get-MoonlightPath }
        $arguments = & $module { param($a, $c) Get-MoonlightStreamArguments -Address $a -Client $c } $endpoint.Address $state['config']['streaming']['client']
        # Peak of Moonlight's sessions; Measure formats numbers with the current culture ("0,353").
        $moonlightPeak = {
            $ids = @(Get-Process moonlight -ErrorAction SilentlyContinue | ForEach-Object Id)
            $peaks = foreach ($s in [AudioSessions]::Measure($Seconds)) {
                if ([int]$s[0] -in $ids) { [double]::Parse($s[4], [cultureinfo]::CurrentCulture) }
            }
            if ($null -ne $peaks) { (@($peaks) | Measure-Object -Maximum).Maximum } elseif ($ids) { 'no audio session' } else { 'moonlight not running' }
        }
        # Steam Streaming Speakers, when the VM has it, is the positive control: it is known to carry sound.
        $sinks = @($cables) + @($original.outputs | Where-Object { $_ -like '*Steam Streaming Speakers*' })
        foreach ($cable in $sinks) {
            Write-Host "`n== virtual_sink = $cable" -ForegroundColor Cyan
            Invoke-Command -VMName $Name -Credential $guest -ArgumentList $cable -ScriptBlock $restartSunshine
            Start-Sleep -Seconds 5
            & $module { param($a, $c) Wait-SunshineReady -Address $a -Credential $c -TimeoutSec 120 } $endpoint.Address $sunshine
            Get-Process moonlight -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep -Seconds 2
            & $module { param($f, $a) Start-UnelevatedProcess -FilePath $f -ArgumentList $a } $moonlight $arguments | Out-Null
            Start-Sleep -Seconds 15
            $silence = & $moonlightPeak
            Invoke-Command -VMName $Name -Credential $guest -ArgumentList $playTask, ($Seconds + 4) -ScriptBlock {
                param($play, $s) & ([scriptblock]::Create($play)) $s; Start-ScheduledTask -TaskName 'GpuVM-Lab011-Play'
            }
            Start-Sleep -Milliseconds 1500
            $withSound = & $moonlightPeak
            $log = Invoke-Command -VMName $Name -Credential $guest -ScriptBlock {
                Stop-ScheduledTask -TaskName 'GpuVM-Lab011-Play' -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName 'GpuVM-Lab011-Play' -Confirm:$false -ErrorAction SilentlyContinue
                Get-Content 'C:\Program Files\Sunshine\config\sunshine.log' -Tail 300 |
                    Where-Object { $_ -match 'audio|sink|Audio' } | Select-Object -Last 12
            }
            $row = [pscustomobject]@{ sink = $cable; moonlightPeakSilence = $silence; moonlightPeakWithSound = $withSound; sunshineLog = @($log) }
            $report.endToEnd += $row
            $row | Format-List sink, moonlightPeakSilence, moonlightPeakWithSound | Out-Host
        }
    }
}
catch { $report.error = "$($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)"; Write-Warning $report.error }
finally {
    # 3. Everything back: virtual_sink, default output, Sunshine running as before, our Moonlight closed.
    try {
        if (-not $SkipEndToEnd) {
            Get-Process moonlight -ErrorAction SilentlyContinue | Stop-Process -Force
            Invoke-Command -VMName $Name -Credential $guest -ArgumentList $original.sink -ScriptBlock $restartSunshine
        }
        Invoke-Command -VMName $Name -Credential $guest -ArgumentList $guestAudio, $original.defaultId -ScriptBlock {
            param($code, $id) . ([scriptblock]::Create($code)); [LabAudio]::SetDefaultById($id)
        }
        $report.restored = $true
    }
    catch { $report.restored = "error: $($_.Exception.Message)" }
    $report.finishedAt = (Get-Date).ToString('o')
    New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
    $report | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 $OutFile
    Write-Host "`nResultado: $OutFile" -ForegroundColor Green
}
