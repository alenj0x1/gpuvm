# The host's monitors, and placing Moonlight on the one chosen to open a VM on. Moonlight has no option for this: it
# streams on the monitor its own window is on, and Windows places that window anywhere. So GpuVM moves Moonlight's
# window to the chosen monitor as soon as it appears, before the stream window is created.
# A monitor is saved by its device path, which stays the same across restarts and when other monitors change;
# "primary" (or nothing) follows whatever monitor Windows has as the primary one.

if (-not ('GpuVMMonitors' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class GpuVMMonitor {
    public string Id; public string Name; public string Device;
    public int X, Y, Width, Height; public double Hz; public bool Primary;
}

public static class GpuVMMonitors {
    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct RATIONAL { public uint Numerator, Denominator; }
    [StructLayout(LayoutKind.Sequential)] struct PATH_SOURCE { public LUID Adapter; public uint Id; public uint ModeIndex; public uint Flags; }
    [StructLayout(LayoutKind.Sequential)] struct PATH_TARGET {
        public LUID Adapter; public uint Id; public uint ModeIndex; public uint Technology; public uint Rotation; public uint Scaling;
        public RATIONAL Refresh; public uint ScanLine; public int Available; public uint Flags;
    }
    [StructLayout(LayoutKind.Sequential)] struct PATH { public PATH_SOURCE Source; public PATH_TARGET Target; public uint Flags; }
    [StructLayout(LayoutKind.Sequential)] struct POINTL { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct SOURCE_MODE { public uint Width, Height, Format; public POINTL Position; }
    [StructLayout(LayoutKind.Explicit, Size = 64)] struct MODE {
        [FieldOffset(0)] public uint InfoType; [FieldOffset(4)] public uint Id; [FieldOffset(8)] public LUID Adapter;
        [FieldOffset(16)] public SOURCE_MODE Source;
    }
    [StructLayout(LayoutKind.Sequential)] struct HEADER { public uint Type; public uint Size; public LUID Adapter; public uint Id; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct SOURCE_NAME {
        public HEADER Header; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string GdiName;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct TARGET_NAME {
        public HEADER Header; public uint Flags; public uint Technology; public ushort EdidManufacturer; public ushort EdidProduct;
        public uint ConnectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string FriendlyName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DevicePath;
    }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths, [Out] PATH[] pathArray, ref uint modes, [Out] MODE[] modeArray, IntPtr topology);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref SOURCE_NAME info);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref TARGET_NAME info);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int cmd);
    delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder name, int size);

    // Physical pixels, the same units QueryDisplayConfig gives, whatever the scaling of each monitor.
    static readonly IntPtr PerMonitorV2 = new IntPtr(-4);

    // The active monitors (a mirrored one counts once), left to right.
    public static List<GpuVMMonitor> List() {
        var list = new List<GpuVMMonitor>();
        uint paths, modes;
        if (GetDisplayConfigBufferSizes(2, out paths, out modes) != 0) return list;
        var pathArray = new PATH[paths];
        var modeArray = new MODE[modes];
        if (QueryDisplayConfig(2, ref paths, pathArray, ref modes, modeArray, IntPtr.Zero) != 0) return list;
        var seen = new HashSet<string>();
        for (int i = 0; i < paths; i++) {
            var p = pathArray[i];
            uint m = p.Source.ModeIndex;
            if (m >= modes || modeArray[m].InfoType != 1) continue;
            var source = new SOURCE_NAME();
            source.Header.Type = 1; source.Header.Size = (uint)Marshal.SizeOf(typeof(SOURCE_NAME));
            source.Header.Adapter = p.Source.Adapter; source.Header.Id = p.Source.Id;
            string gdi = DisplayConfigGetDeviceInfo(ref source) == 0 ? source.GdiName : "";
            if (!seen.Add(gdi + "|" + p.Source.Adapter.Low + "|" + p.Source.Id)) continue;
            var target = new TARGET_NAME();
            target.Header.Type = 2; target.Header.Size = (uint)Marshal.SizeOf(typeof(TARGET_NAME));
            target.Header.Adapter = p.Target.Adapter; target.Header.Id = p.Target.Id;
            bool named = DisplayConfigGetDeviceInfo(ref target) == 0;
            var mode = modeArray[m].Source;
            var r = p.Target.Refresh;
            list.Add(new GpuVMMonitor {
                Id = named && !string.IsNullOrEmpty(target.DevicePath) ? target.DevicePath : gdi,
                Name = named ? target.FriendlyName : "",
                Device = gdi,
                X = mode.Position.X, Y = mode.Position.Y, Width = (int)mode.Width, Height = (int)mode.Height,
                Hz = r.Denominator == 0 ? 0 : Math.Round((double)r.Numerator / r.Denominator, 2),
                Primary = mode.Position.X == 0 && mode.Position.Y == 0,
            });
        }
        list.Sort((a, b) => a.X != b.X ? a.X.CompareTo(b.X) : a.Y.CompareTo(b.Y));
        return list;
    }

    // The visible top-level windows of a process, as "handle|class" (Moonlight: its Qt window, then SDL's stream window).
    public static List<string> Windows(int pid) {
        var found = new List<string>();
        EnumWindows((h, l) => {
            uint owner;
            GetWindowThreadProcessId(h, out owner);
            if (owner == (uint)pid && IsWindowVisible(h)) {
                var name = new System.Text.StringBuilder(128);
                GetClassName(h, name, name.Capacity);
                found.Add(h.ToInt64() + "|" + name);
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Moves a window onto the monitor whose top-left corner is (x, y) and size w x h, centered and keeping its size
    // (shrunk to fit). A maximized window is restored first so it can move, then maximized there again.
    // Returns true when the window ends up with its center inside that monitor.
    public static bool MoveTo(IntPtr hWnd, int x, int y, int w, int h) {
        IntPtr previous = SetThreadDpiAwarenessContext(PerMonitorV2);
        try {
            if (hWnd == IntPtr.Zero || !IsWindowVisible(hWnd)) return false;
            RECT rect;
            if (!GetWindowRect(hWnd, out rect)) return false;
            int cx = (rect.Left + rect.Right) / 2, cy = (rect.Top + rect.Bottom) / 2;
            if (cx >= x && cx < x + w && cy >= y && cy < y + h) return true;
            bool maximized = IsZoomed(hWnd);
            if (maximized) { ShowWindow(hWnd, 9); GetWindowRect(hWnd, out rect); }
            int width = Math.Min(rect.Right - rect.Left, w), height = Math.Min(rect.Bottom - rect.Top, h);
            // SWP_NOZORDER | SWP_NOACTIVATE
            SetWindowPos(hWnd, IntPtr.Zero, x + (w - width) / 2, y + (h - height) / 2, width, height, 0x0004 | 0x0010);
            if (maximized) ShowWindow(hWnd, 3);
            if (!GetWindowRect(hWnd, out rect)) return false;
            cx = (rect.Left + rect.Right) / 2; cy = (rect.Top + rect.Bottom) / 2;
            return cx >= x && cx < x + w && cy >= y && cy < y + h;
        }
        finally { if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous); }
    }
}
'@
}

# The host's active monitors, left to right, with a readable name (the monitor's own, or "Monitor N").
function Get-HostMonitor {
    $all = @([GpuVMMonitors]::List())
    $i = 0
    foreach ($m in $all) {
        $i++
        [ordered]@{
            id = $m.Id
            name = if ($m.Name) { $m.Name } else { "Monitor $i" }
            primary = $m.Primary
            x = $m.X; y = $m.Y; width = $m.Width; height = $m.Height
            hz = [int][math]::Round($m.Hz)
        }
    }
}

# The monitor to open on: the chosen one if it is connected, otherwise the primary one. $null when none can be read
# (no desktop session).
function Resolve-HostMonitor {
    param([string]$Monitor)
    $all = @(Get-HostMonitor)
    if (-not $all) { return $null }
    if ($Monitor -and $Monitor -ne 'primary') {
        $chosen = $all | Where-Object { $_['id'] -eq $Monitor } | Select-Object -First 1
        if ($chosen) { return $chosen }
        Write-Step 'El monitor elegido no está conectado: se abre en el principal'
    }
    $primary = $all | Where-Object { $_['primary'] } | Select-Object -First 1
    if ($primary) { $primary } else { $all[0] }
}

# Keeps Moonlight's windows (started since $Since) on the monitor until its stream window is there. The stream
# window is created on the monitor the main window is on, so the main one is moved as soon as it appears; Moonlight
# can still put it back while it starts, so it is checked again, and a stream window that opened elsewhere is moved
# too (it stays there, fullscreen included).
function Move-MoonlightToMonitor {
    param(
        [Parameter(Mandatory)][datetime]$Since,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Monitor,
        [int]$TimeoutSec = 30
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $seen = $false
    # The stream window goes fullscreen a moment after it appears: it has to stay on the monitor for a second.
    $streamSince = $null
    while ((Get-Date) -lt $deadline) {
        $processes = @(Get-Process Moonlight -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -ge $Since.AddSeconds(-2) })
        if ($seen -and -not $processes) { return }
        foreach ($process in $processes) {
            $seen = $true
            foreach ($window in [GpuVMMonitors]::Windows($process.Id)) {
                $handle, $class = $window.Split('|', 2)
                $placed = [GpuVMMonitors]::MoveTo([IntPtr][long]$handle, $Monitor['x'], $Monitor['y'], $Monitor['width'], $Monitor['height'])
                if ($class -like 'SDL*') {
                    if (-not $placed) { $streamSince = $null }
                    elseif (-not $streamSince) { $streamSince = Get-Date }
                    elseif (((Get-Date) - $streamSince).TotalSeconds -ge 1) { return }
                }
            }
        }
        Start-Sleep -Milliseconds 50
    }
}
