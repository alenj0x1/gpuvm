# Sets the virtual display (VDD) resolution and refresh rate to the ones Moonlight uses.
# Runs inside the VM, in the user's session (launched by a scheduled task from GpuVM). Windows PowerShell 5.1.
param(
    [Parameter(Mandatory)][int]$Width,
    [Parameter(Mandatory)][int]$Height,
    [int]$Refresh = 60,
    [string]$Out = 'C:\GpuVM\resolution.json'
)

# All display logic lives in C#: modifying native structures from PowerShell is not reliable.
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

public static class GpuVMDisplay {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
        public int dmFields; public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
        public int dmDisplayFlags; public int dmDisplayFrequency; public int dmICMMethod; public int dmICMIntent;
        public int dmMediaType; public int dmDitherType; public int dmReserved1; public int dmReserved2;
        public int dmPanningWidth; public int dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplayDevices(string device, uint index, ref DISPLAY_DEVICE info, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE info);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int ChangeDisplaySettingsEx(string device, ref DEVMODE mode, IntPtr hwnd, uint flags, IntPtr param);

    /// Name (\\.\DISPLAYn) of the first adapter whose description matches the pattern, or null.
    public static string FindDevice(string pattern) {
        for (uint i = 0; i < 32; i++) {
            var d = new DISPLAY_DEVICE();
            d.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (!EnumDisplayDevices(null, i, ref d, 0)) break;
            if (Regex.IsMatch(d.DeviceString ?? "", pattern, RegexOptions.IgnoreCase)) return d.DeviceName;
        }
        return null;
    }

    public static string[] Devices() {
        var list = new List<string>();
        for (uint i = 0; i < 32; i++) {
            var d = new DISPLAY_DEVICE();
            d.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (!EnumDisplayDevices(null, i, ref d, 0)) break;
            list.Add(d.DeviceName + " | " + d.DeviceString);
        }
        return list.ToArray();
    }

    public static string[] Modes(string device) {
        var list = new List<string>();
        for (int m = 0; m < 4096; m++) {
            var mode = new DEVMODE();
            mode.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettings(device, m, ref mode)) break;
            string text = mode.dmPelsWidth + "x" + mode.dmPelsHeight + "@" + mode.dmDisplayFrequency;
            if (!list.Contains(text)) list.Add(text);
        }
        return list.ToArray();
    }

    /// Applies the mode of that size with the highest refresh rate not above 'hz'.
    /// Returns the ChangeDisplaySettingsEx code (0 = success) or -100 if there is no mode of that size.
    public static int SetMode(string device, int width, int height, int hz, out string applied) {
        applied = null;
        DEVMODE best = new DEVMODE();
        bool found = false;
        for (int m = 0; m < 4096; m++) {
            var mode = new DEVMODE();
            mode.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettings(device, m, ref mode)) break;
            if (mode.dmPelsWidth != width || mode.dmPelsHeight != height || mode.dmDisplayFrequency > hz) continue;
            if (!found || mode.dmDisplayFrequency > best.dmDisplayFrequency) { best = mode; found = true; }
        }
        if (!found) return -100;
        applied = best.dmPelsWidth + "x" + best.dmPelsHeight + "@" + best.dmDisplayFrequency;
        // Already in that mode: no change, so Sunshine doesn't see a display change and re-test its encoders (~15 s).
        var current = new DEVMODE();
        current.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (EnumDisplaySettings(device, -1, ref current) && current.dmPelsWidth == best.dmPelsWidth &&
            current.dmPelsHeight == best.dmPelsHeight && current.dmDisplayFrequency == best.dmDisplayFrequency) return 0;
        best.dmFields = 0x80000 | 0x100000 | 0x400000;   // width, height and frequency
        return ChangeDisplaySettingsEx(device, ref best, IntPtr.Zero, 0x1, IntPtr.Zero);   // CDS_UPDATEREGISTRY
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsEx")]
    static extern int ApplyDisplaySettings(string device, IntPtr mode, IntPtr hwnd, uint flags, IntPtr param);

    /// Makes 'device' the primary display at (0,0) and turns every other display of the desktop off, saved in the
    /// registry so it stays that way. GPU-P guests get an extra 1024x768 output that would otherwise be the primary
    /// one, so new windows (Steam, installers) would open where the stream doesn't show them.
    /// Returns the names of the displays turned off, or null if Windows refused the change.
    public static string[] MakeOnlyDisplay(string device) {
        const uint UPDATEREGISTRY = 0x1, SET_PRIMARY = 0x10, NORESET = 0x10000000;
        const int POSITION = 0x20, WIDTH = 0x80000, HEIGHT = 0x100000;
        var off = new List<string>();
        var primary = new DEVMODE();
        primary.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettings(device, -1, ref primary)) return null;   // ENUM_CURRENT_SETTINGS
        // Nothing to do if it is already alone at 0,0: any change would make Sunshine re-test its encoders.
        bool alone = primary.dmPositionX == 0 && primary.dmPositionY == 0;
        for (uint i = 0; alone && i < 32; i++) {
            var d = new DISPLAY_DEVICE();
            d.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (!EnumDisplayDevices(null, i, ref d, 0)) break;
            if (d.DeviceName != device && (d.StateFlags & 0x1) != 0) alone = false;
        }
        if (alone) return off.ToArray();
        primary.dmPositionX = 0; primary.dmPositionY = 0;
        primary.dmFields = POSITION;
        if (ChangeDisplaySettingsEx(device, ref primary, IntPtr.Zero, UPDATEREGISTRY | SET_PRIMARY | NORESET, IntPtr.Zero) != 0) return null;
        for (uint i = 0; i < 32; i++) {
            var d = new DISPLAY_DEVICE();
            d.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (!EnumDisplayDevices(null, i, ref d, 0)) break;
            if (d.DeviceName == device || (d.StateFlags & 0x1) == 0) continue;   // not attached to the desktop
            var detach = new DEVMODE();
            detach.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            detach.dmDeviceName = d.DeviceName;
            detach.dmFields = POSITION | WIDTH | HEIGHT;   // a 0x0 size at 0,0 removes it from the desktop
            if (ChangeDisplaySettingsEx(d.DeviceName, ref detach, IntPtr.Zero, UPDATEREGISTRY | NORESET, IntPtr.Zero) == 0) off.Add(d.DeviceName);
        }
        return ApplyDisplaySettings(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero) == 0 ? off.ToArray() : null;
    }
}
"@

function Write-Result($Data) { $Data | ConvertTo-Json -Depth 4 | Set-Content -Path $Out -Encoding UTF8 }

try {
    $device = [GpuVMDisplay]::FindDevice('Virtual Display|MttVDD|IddSample')
    if (-not $device) {
        Write-Result @{ ok = $false; error = 'No se encontró la pantalla virtual.'; devices = [GpuVMDisplay]::Devices() -join '; ' }
        return
    }
    $applied = $null
    $code = [GpuVMDisplay]::SetMode($device, $Width, $Height, $Refresh, [ref]$applied)
    if ($code -eq -100) {
        Write-Result @{ ok = $false; error = "La pantalla virtual no ofrece ${Width}x${Height}."; available = ([GpuVMDisplay]::Modes($device) -join ', ') }
        return
    }
    # Sunshine no longer rearranges displays per session (that costs ~20 s), so GpuVM leaves the virtual one alone.
    $off = [GpuVMDisplay]::MakeOnlyDisplay($device)
    $result = @{ ok = ($code -eq 0 -and $null -ne $off); code = $code; device = $device; applied = $applied; turnedOff = (@($off) -join ', ') }
    if ($null -eq $off) { $result.error = 'Windows no dejó apagar las otras pantallas de la VM.' }
    Write-Result $result
}
catch {
    Write-Result @{ ok = $false; error = "$_" }
}
