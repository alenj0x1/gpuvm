# Audio investigation in one run, no questions asked. Writes everything to out\audio-fix-*.json.
# 1. Reads which output Sunshine captures (virtual_sink) and checks Sunshine answers.
# 2. Reads volume and mute of every output inside the VM.
# 3. Plays a sound in the user's session and captures each output by WASAPI loopback (what Sunshine does).
# 4. If the VB-CABLE output is muted or at a low volume, unmutes it at 100 % and captures again.
# pwsh -File labs\010-network-isolation\audio-fix.ps1
param(
    [string]$Name = (Get-VM | Where-Object Notes -like "Creada con GpuVM*" | Select-Object -First 1).Name,
    [string]$OutFile = (Join-Path $PSScriptRoot "out\audio-fix-$(Get-Date -Format yyyyMMdd-HHmmss).json")
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$module = Get-Module GpuVM
$report = [ordered]@{ vm = $Name; steps = [ordered]@{} }

$audioCode = @'
param([string]$Mode, [int]$Seconds = 4, [string]$Fix, [string]$Default, [string]$PlayTask, [string]$ResetFormat)
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class Audio {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class En {}
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator { int EnumAudioEndpoints(int f, int m, out IMMDeviceCollection c); int GetDefaultAudioEndpoint(int f, int r, out IMMDevice d); }
    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection { int GetCount(out int c); int Item(int i, out IMMDevice d); }
    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice { int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); int OpenPropertyStore(int a, out IPropertyStore s); int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id); }
    [Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore { int GetCount(out int c); int GetAt(int i, out PropertyKey k); int GetValue(ref PropertyKey k, out PropVariant v); }
    [StructLayout(LayoutKind.Sequential)] struct PropertyKey { public Guid fmtid; public int pid; }
    [StructLayout(LayoutKind.Explicit)] struct PropVariant { [FieldOffset(0)] public short vt; [FieldOffset(8)] public IntPtr p; }
    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume {
        int RegisterControlChangeNotify(IntPtr n); int UnregisterControlChangeNotify(IntPtr n); int GetChannelCount(out uint c);
        int SetMasterVolumeLevel(float l, ref Guid g); int SetMasterVolumeLevelScalar(float l, ref Guid g);
        int GetMasterVolumeLevel(out float l); int GetMasterVolumeLevelScalar(out float l);
        int SetChannelVolumeLevel(uint c, float l, ref Guid g); int SetChannelVolumeLevelScalar(uint c, float l, ref Guid g);
        int GetChannelVolumeLevel(uint c, out float l); int GetChannelVolumeLevelScalar(uint c, out float l);
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool m, ref Guid g); int GetMute([MarshalAs(UnmanagedType.Bool)] out bool m);
    }
    [Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation { int GetPeakValue(out float peak); }
    [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")] class PolicyConfigCom {}
    [Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPolicyConfig {
        int GetMixFormat(); int GetDeviceFormat(); int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id); int SetDeviceFormat(); int GetProcessingPeriod(); int SetProcessingPeriod();
        int GetShareMode(); int SetShareMode(); int GetPropertyValue(); int SetPropertyValue();
        int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
    }
    // Makes the output with this name the default for every role; returns the id that was default before.
    public static string SetDefault(string name) {
        string defaultId; var devices = Devices(out defaultId);
        foreach (var d in devices) {
            if (Name(d) != name) continue;
            string id; d.GetId(out id); var pc = (IPolicyConfig)new PolicyConfigCom();
            for (int role = 0; role < 3; role++) pc.SetDefaultEndpoint(id, role);
            return defaultId;
        }
        return null;
    }
    // Back to the driver's default format (what Sunshine changed to S24 on every stream).
    public static List<string> ResetFormat(string nameLike) {
        string defaultId; var r = new List<string>();
        foreach (var d in Devices(out defaultId)) {
            var n = Name(d); if (!n.Contains(nameLike)) continue;
            string id; d.GetId(out id);
            int hr = ((IPolicyConfig)new PolicyConfigCom()).ResetDeviceFormat(id);
            r.Add(n + " reset 0x" + hr.ToString("X"));
        }
        return r;
    }
    public static void SetDefaultById(string id) { var pc = (IPolicyConfig)new PolicyConfigCom(); for (int role = 0; role < 3; role++) pc.SetDefaultEndpoint(id, role); }
    [Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient {
        int Initialize(int share, int flags, long dur, long period, IntPtr fmt, IntPtr session);
        int GetBufferSize(out uint n); int GetStreamLatency(out long l); int GetCurrentPadding(out uint p);
        int IsFormatSupported(int s, IntPtr f, out IntPtr c); int GetMixFormat(out IntPtr f); int GetDevicePeriod(out long d, out long m);
        int Start(); int Stop(); int Reset(); int SetEventHandle(IntPtr h); int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object o);
    }
    [Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioCaptureClient { int GetBuffer(out IntPtr data, out uint frames, out uint flags, out long pos, out long qpc); int ReleaseBuffer(uint n); int GetNextPacketSize(out uint n); }

    static List<IMMDevice> Devices(out string defaultId) {
        var e = (IMMDeviceEnumerator)new En();
        IMMDevice def; e.GetDefaultAudioEndpoint(0, 0, out def); def.GetId(out defaultId);
        IMMDeviceCollection col; e.EnumAudioEndpoints(0, 1, out col);
        int n; col.GetCount(out n); var list = new List<IMMDevice>();
        for (int i = 0; i < n; i++) { IMMDevice d; col.Item(i, out d); list.Add(d); }
        return list;
    }
    static string Name(IMMDevice d) {
        IPropertyStore ps; d.OpenPropertyStore(0, out ps);
        var key = new PropertyKey { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };
        PropVariant v; ps.GetValue(ref key, out v); return Marshal.PtrToStringUni(v.p);
    }
    static T Get<T>(IMMDevice d) { var iid = typeof(T).GUID; object o; d.Activate(ref iid, 23, IntPtr.Zero, out o); return (T)o; }

    public static List<Dictionary<string, object>> Inspect(int seconds, string fix) {
        string defaultId; var result = new List<Dictionary<string, object>>();
        var devices = Devices(out defaultId);
        var clients = new List<IAudioClient>(); var captures = new List<IAudioCaptureClient>(); var bits = new List<int>(); var chans = new List<int>();
        var peaks = new float[devices.Count]; var meterPeaks = new float[devices.Count]; var packets = new long[devices.Count];
        var nonzero = new long[devices.Count]; var silent = new long[devices.Count]; var blockAlign = new int[devices.Count]; var meters = new List<IAudioMeterInformation>();
        foreach (var d in devices) {
            string id; d.GetId(out id); var info = new Dictionary<string, object>(); result.Add(info);
            info["name"] = Name(d); info["default"] = id == defaultId;
            IAudioMeterInformation meter = null; IAudioClient client = null; IAudioCaptureClient capture = null; int b = 0, c = 0;
            try {
                var vol = Get<IAudioEndpointVolume>(d); float level; bool mute; vol.GetMasterVolumeLevelScalar(out level); vol.GetMute(out mute);
                if (fix != null && fix.Length > 0 && info["name"].ToString() == fix) {
                    var g = Guid.Empty; vol.SetMute(false, ref g); vol.SetMasterVolumeLevelScalar(1.0f, ref g);
                    info["fixedFrom"] = "volume=" + level.ToString("0.00") + " mute=" + mute;
                    vol.GetMasterVolumeLevelScalar(out level); vol.GetMute(out mute);
                }
                info["volume"] = Math.Round(level, 2); info["mute"] = mute;
                meter = Get<IAudioMeterInformation>(d);
                var ac = Get<IAudioClient>(d); IntPtr fmt; ac.GetMixFormat(out fmt);
                b = Marshal.ReadInt16(fmt, 14); c = Marshal.ReadInt16(fmt, 2);
                info["format"] = "tag=0x" + ((ushort)Marshal.ReadInt16(fmt, 0)).ToString("X") + " ch=" + c + " rate=" + Marshal.ReadInt32(fmt, 4) + " bits=" + b;
                blockAlign[result.Count - 1] = Marshal.ReadInt16(fmt, 12);
                int hr = ac.Initialize(0, 0x00020000, 2000000, 0, fmt, IntPtr.Zero);
                if (hr != 0) info["loopback"] = "Initialize 0x" + hr.ToString("X");
                else { var cid = typeof(IAudioCaptureClient).GUID; object co; ac.GetService(ref cid, out co); capture = (IAudioCaptureClient)co; client = ac; ac.Start(); }
            } catch (Exception ex) { info["error"] = ex.Message.Trim() + " at " + ex.TargetSite; }
            meters.Add(meter); clients.Add(client); captures.Add(capture); bits.Add(b); chans.Add(c);
        }
        var end = DateTime.Now.AddSeconds(seconds);
        while (DateTime.Now < end) {
            for (int i = 0; i < devices.Count; i++) {
                if (meters[i] != null) { float mp; meters[i].GetPeakValue(out mp); if (mp > meterPeaks[i]) meterPeaks[i] = mp; }
                var cc = captures[i]; if (cc == null) continue;
                uint size; cc.GetNextPacketSize(out size);
                while (size > 0) {
                    IntPtr data; uint nf, flags; long p, q; cc.GetBuffer(out data, out nf, out flags, out p, out q);
                    packets[i]++; if ((flags & 2) != 0) silent[i]++;
                    else { int len = (int)nf * blockAlign[i]; for (int k = 0; k < len; k++) if (Marshal.ReadByte(data, k) != 0) nonzero[i]++; }
                    if ((flags & 2) == 0 && bits[i] == 32) for (int k = 0; k < nf * chans[i]; k++) { float v = Math.Abs(BitConverter.ToSingle(BitConverter.GetBytes(Marshal.ReadInt32(data, k * 4)), 0)); if (v > peaks[i]) peaks[i] = v; }
                    cc.ReleaseBuffer(nf); cc.GetNextPacketSize(out size);
                }
            }
            System.Threading.Thread.Sleep(10);
        }
        for (int i = 0; i < devices.Count; i++) {
            if (clients[i] != null) { clients[i].Stop(); result[i]["loopbackPackets"] = packets[i]; result[i]["silentPackets"] = silent[i]; result[i]["nonzeroBytes"] = nonzero[i]; result[i]["loopbackPeak"] = Math.Round(peaks[i], 3); }
            result[i]["meterPeak"] = Math.Round(meterPeaks[i], 3);
        }
        return result;
    }
}
"@
if ($ResetFormat) { [Audio]::ResetFormat($ResetFormat) | ForEach-Object { Write-Host $_ }; Start-Sleep -Seconds 1 }
$previous = if ($Default) { [Audio]::SetDefault($Default) } else { $null }
# The sound starts after the default is set, so it opens on the output being tested.
if ($PlayTask) { Start-Sleep -Milliseconds 300; Start-ScheduledTask -TaskName $PlayTask; Start-Sleep -Milliseconds 1200 }
try { $rows = [Audio]::Inspect($Seconds, $Fix) } finally { if ($previous) { [Audio]::SetDefaultById($previous) } }
$rows | ForEach-Object { $h = [ordered]@{}; foreach ($k in $_.Keys) { $h[$k] = $_[$k] }; [pscustomobject]$h }
'@

try {
    $state = & $module { param($n) Get-GpuVMState -Name $n } $Name
    $guest = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state
    $sunshine = & $module { param($s) Get-SunshineCredential -State $s } $state

    # 1. Only reads the sink: restarting Sunshine here broke it in "wgc" capture mode (it runs from a logon task).
    $report.steps['sunshine'] = Invoke-Command -VMName $Name -Credential $guest -ScriptBlock {
        [pscustomobject]@{ sink = ((Get-Content 'C:\Program Files\Sunshine\config\sunshine.conf' | Where-Object { $_ -match '^\s*virtual_sink\s*=' }) -replace '^\s*virtual_sink\s*=\s*', '').Trim() }
    } | Select-Object sink
    $endpoint = & $module { param($n) Get-GpuVMEndpoint -Name $n -TimeoutSec 120 } $Name
    & $module { param($a, $c) Wait-SunshineReady -Address $a -Credential $c -TimeoutSec 120 } $endpoint.Address $sunshine
    $report.steps['sunshineReady'] = $true

    # 2-4. Measure with a sound playing in the user's session; fix the VB-CABLE output if needed and measure again.
    $measure = {
        param($fix, $default, $reset)
        Invoke-Command -VMName $Name -Credential $guest -ArgumentList $audioCode, $fix, $default, $reset -ScriptBlock {
            param($code, $fix, $default, $reset)
            $user = (Get-CimInstance Win32_ComputerSystem).UserName
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -Command `$p=[Media.SoundPlayer]::new('C:\Windows\Media\Alarm01.wav');`$p.PlayLooping();Start-Sleep 8"
            Register-ScheduledTask -TaskName 'GpuVM-Lab010-Play' -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive) -Force | Out-Null
            try {
                & ([scriptblock]::Create($code)) -Seconds 5 -Fix $fix -Default $default -PlayTask 'GpuVM-Lab010-Play' -ResetFormat $reset
            }
            finally { Unregister-ScheduledTask -TaskName 'GpuVM-Lab010-Play' -Confirm:$false -ErrorAction SilentlyContinue }
        } | Select-Object name, default, volume, mute, fixedFrom, error, format, meterPeak, loopbackPackets, silentPackets, nonzeroBytes, loopbackPeak
    }
    $before = @(& $measure '' '' '')
    $report.steps['before'] = $before
    $cable = $before | Where-Object { $_.name -eq $report.steps['sunshine'].sink }
    $report.steps['cableNeedsFix'] = [bool]($cable -and ($cable.mute -or $cable.volume -lt 0.5))
    if ($cable -and ($cable.mute -or $cable.volume -lt 0.5)) {
        $report.steps['after'] = @(& $measure $cable.name '' '')
    }
    # 5. Steam Streaming Speakers (installed by Sunshine) as the default output for the test, then restored.
    $steam = ($before | Where-Object { $_.name -like '*Steam Streaming Speakers*' } | Select-Object -First 1).name
    if ($steam -and -not $SkipSteam) { $report.steps['steam'] = @(& $measure '' $steam '') }
    # 6. Another output as the default for the test, then restored.
    if ($TryDefault) { $report.steps['try'] = @(& $measure '' $TryDefault '') }
}
catch { $report['error'] = "$($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)" }
finally {
    New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
    $report | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 $OutFile
}
