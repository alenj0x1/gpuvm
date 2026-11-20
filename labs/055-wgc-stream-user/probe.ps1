# Lab 055, inside the guest: the Windows.Graphics.Capture calls Sunshine's display_wgc.cpp makes before its first frame
# (activation factory of GraphicsCaptureItem, CreateForMonitor on the primary monitor), each with its HRESULT, run as
# whoever starts it. Writes C:\GpuVMLab055\out\probe-<user>.txt. Windows PowerShell 5.1.
$out = 'C:\GpuVMLab055\out'
$file = Join-Path $out "probe-$env:USERNAME.txt"
function W($s) { Add-Content $file "$(Get-Date -Format HH:mm:ss.fff) $s" }
try {
    Add-Type @'
using System; using System.Runtime.InteropServices;
[ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IGraphicsCaptureItemInterop {
    [PreserveSig] int CreateForWindow(IntPtr window, ref Guid iid, out IntPtr result);
    [PreserveSig] int CreateForMonitor(IntPtr monitor, ref Guid iid, out IntPtr result);
}
public static class Probe055 {
    [DllImport("combase.dll")] static extern int RoInitialize(int type);
    [DllImport("combase.dll", CharSet = CharSet.Unicode)] static extern int WindowsCreateString(string s, int len, out IntPtr h);
    [DllImport("combase.dll")] static extern int RoGetActivationFactory(IntPtr cls, ref Guid iid, out IntPtr factory);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(long pt, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    public static string Run() {
        var r = new System.Text.StringBuilder();
        r.AppendFormat("RoInitialize 0x{0:X8}; ", RoInitialize(1));
        IntPtr h; WindowsCreateString("Windows.Graphics.Capture.GraphicsCaptureItem", 45, out h);
        Guid iid = typeof(IGraphicsCaptureItemInterop).GUID; IntPtr f;
        int hr = RoGetActivationFactory(h, ref iid, out f);
        r.AppendFormat("RoGetActivationFactory 0x{0:X8}; ", hr);
        if (hr != 0) return r.ToString();
        var interop = (IGraphicsCaptureItemInterop)Marshal.GetObjectForIUnknown(f);
        IntPtr mon = MonitorFromPoint(0, 1);
        r.AppendFormat("monitor 0x{0:X}; desktop 0x{1:X}; ", mon.ToInt64(), GetThreadDesktop(GetCurrentThreadId()).ToInt64());
        Guid item = new Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760"); IntPtr it;
        r.AppendFormat("CreateForMonitor 0x{0:X8}", interop.CreateForMonitor(mon, ref item, out it));
        return r.ToString();
    }
}
'@
    W "$([Security.Principal.WindowsIdentity]::GetCurrent().Name) session $((Get-Process -Id $PID).SessionId): $([Probe055]::Run())"
}
catch { W "ERROR $($_.Exception.Message)" }
