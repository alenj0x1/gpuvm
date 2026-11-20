
using System; using System.Runtime.InteropServices;
[ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IGraphicsCaptureItemInterop {
    [PreserveSig] int CreateForWindow(IntPtr window, ref Guid iid, out IntPtr result);
    [PreserveSig] int CreateForMonitor(IntPtr monitor, ref Guid iid, out IntPtr result);
}
public static class Probe055 {
    public static void Main() {
        string who = System.Security.Principal.WindowsIdentity.GetCurrent().Name;
        string line;
        try { line = Run(); } catch (Exception e) { line = "EXCEPTION " + e.Message; }
        System.IO.File.AppendAllText(@"C:\GpuVMLab055\out\probe-" + Environment.UserName + ".txt", DateTime.Now.ToString("HH:mm:ss.fff") + " " + who + " session " + System.Diagnostics.Process.GetCurrentProcess().SessionId + ": " + line + Environment.NewLine);
    }
    [DllImport("combase.dll")] static extern int RoInitialize(int type);
    [DllImport("combase.dll", CharSet = CharSet.Unicode)] static extern int WindowsCreateString(string s, int len, out IntPtr h);
    [DllImport("combase.dll")] static extern int RoGetActivationFactory(IntPtr cls, ref Guid iid, out IntPtr factory);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(long pt, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    public static string Run() {
        var r = new System.Text.StringBuilder();
        r.AppendFormat("RoInitialize 0x{0:X8}; ", RoInitialize(1));
        IntPtr h; string cls = "Windows.Graphics.Capture.GraphicsCaptureItem"; WindowsCreateString(cls, cls.Length, out h);
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


