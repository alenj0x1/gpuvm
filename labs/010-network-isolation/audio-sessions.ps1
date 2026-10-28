# Read-only: each app playing on the default output (Volume Mixer), with its volume, mute and peak over a few seconds.
param([int]$Seconds = 6)
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class AudioSessions {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom {}
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator { int NotImpl1(); int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device); }
    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice { int Activate(ref Guid iid, int clsCtx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); }
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
    [Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISimpleAudioVolume { int SetMasterVolume(float v, Guid g); int GetMasterVolume(out float v); int SetMute(bool m, Guid g); int GetMute(out bool m); }
    [Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation { int GetPeakValue(out float peak); }

    public static List<string[]> Measure(int seconds) {
        var e = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
        IMMDevice d; e.GetDefaultAudioEndpoint(0, 0, out d);
        var iid = typeof(IAudioSessionManager2).GUID; object o; d.Activate(ref iid, 23, IntPtr.Zero, out o);
        IAudioSessionEnumerator se; ((IAudioSessionManager2)o).GetSessionEnumerator(out se);
        int n; se.GetCount(out n);
        var pids = new uint[n]; var states = new int[n]; var vols = new float[n]; var mutes = new bool[n];
        var meters = new IAudioMeterInformation[n]; var peaks = new float[n];
        for (int i = 0; i < n; i++) {
            IAudioSessionControl2 s; se.GetSession(i, out s);
            s.GetProcessId(out pids[i]); s.GetState(out states[i]);
            var v = (ISimpleAudioVolume)s; v.GetMasterVolume(out vols[i]); v.GetMute(out mutes[i]);
            meters[i] = (IAudioMeterInformation)s;
        }
        var end = DateTime.Now.AddSeconds(seconds);
        while (DateTime.Now < end) {
            for (int i = 0; i < n; i++) { float p; meters[i].GetPeakValue(out p); if (p > peaks[i]) peaks[i] = p; }
            System.Threading.Thread.Sleep(20);
        }
        var r = new List<string[]>();
        for (int i = 0; i < n; i++) r.Add(new[] { pids[i].ToString(), states[i] == 1 ? "activa" : "inactiva", vols[i].ToString("0.00"), mutes[i] ? "si" : "no", peaks[i].ToString("0.000") });
        return r;
    }
}
'@
[AudioSessions]::Measure($Seconds) | ForEach-Object {
    $process = Get-Process -Id ([int]$_[0]) -ErrorAction SilentlyContinue
    [pscustomobject]@{ App = if ($process) { $process.ProcessName } else { "pid $($_[0])" }; Estado = $_[1]; Volumen = $_[2]; Silenciada = $_[3]; Pico = $_[4] }
} | Format-Table -AutoSize
