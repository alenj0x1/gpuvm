# Read-only: peak level of every active audio output (Core Audio meters) for a few seconds, and which one is the
# default. Runs on the host as the user, or inside the VM (audio-devices.ps1 style) to see if sound reaches VB-CABLE.
param([int]$Seconds = 6)
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class AudioMeter {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom {}
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    }
    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection { int GetCount(out int count); int Item(int index, out IMMDevice device); }
    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        int OpenPropertyStore(int access, out IPropertyStore store);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    }
    [Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore { int GetCount(out int c); int GetAt(int i, out PropertyKey k); int GetValue(ref PropertyKey k, out PropVariant v); }
    [Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation { int GetPeakValue(out float peak); }
    [StructLayout(LayoutKind.Sequential)] struct PropertyKey { public Guid fmtid; public int pid; }
    [StructLayout(LayoutKind.Explicit)] struct PropVariant { [FieldOffset(0)] public short vt; [FieldOffset(8)] public IntPtr p; }

    public static List<string[]> Measure(int seconds) {
        var e = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
        IMMDevice def; e.GetDefaultAudioEndpoint(0, 0, out def);
        string defId; def.GetId(out defId);
        IMMDeviceCollection col; e.EnumAudioEndpoints(0, 1, out col);
        int n; col.GetCount(out n);
        var names = new string[n]; var ids = new string[n]; var meters = new IAudioMeterInformation[n]; var peaks = new float[n];
        var iid = typeof(IAudioMeterInformation).GUID;
        var nameKey = new PropertyKey { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };
        for (int i = 0; i < n; i++) {
            IMMDevice d; col.Item(i, out d); d.GetId(out ids[i]);
            IPropertyStore ps; d.OpenPropertyStore(0, out ps);
            PropVariant v; ps.GetValue(ref nameKey, out v); names[i] = Marshal.PtrToStringUni(v.p);
            object o; d.Activate(ref iid, 23, IntPtr.Zero, out o); meters[i] = (IAudioMeterInformation)o;
        }
        var end = DateTime.Now.AddSeconds(seconds);
        while (DateTime.Now < end) {
            for (int i = 0; i < n; i++) { float p; meters[i].GetPeakValue(out p); if (p > peaks[i]) peaks[i] = p; }
            System.Threading.Thread.Sleep(20);
        }
        var result = new List<string[]>();
        for (int i = 0; i < n; i++) result.Add(new[] { names[i], peaks[i].ToString("0.000"), ids[i] == defId ? "predeterminada" : "" });
        return result;
    }
}
'@
[AudioMeter]::Measure($Seconds) | ForEach-Object { [pscustomobject]@{ Salida = $_[0]; Pico = [double]$_[1]; Predeterminada = $_[2] } } | Format-Table -AutoSize
