# Lab 055: starts GpuVM's viewer the way the app does (app/src-tauri/src/lowbox.rs): this process's token with
# privileges removed, Administrators deny-only, labelled Low; TEMP in LocalLow. At Low the viewer reads its own
# settings and pairing in LocalLow\GpuVM\Viewer. Prints the process id. Windows PowerShell 5.1.
param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string]$CommandLine)
Add-Type @'
using System; using System.ComponentModel; using System.Runtime.InteropServices;
public static class Low055 {
    [StructLayout(LayoutKind.Sequential)] struct SA { public IntPtr Sid; public uint Attr; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct SI { public int cb; public string r, desk, title; public int x, y, w, h, cx, cy, fill, flags; public short show, cb2; public IntPtr r2, i, o, e; }
    [StructLayout(LayoutKind.Sequential)] struct PI { public IntPtr p, t; public int pid, tid; }
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr p, uint a, out IntPtr t);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool CreateRestrictedToken(IntPtr t, uint f, uint nd, SA[] d, uint np, IntPtr p, uint nr, IntPtr r, out IntPtr n);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool ConvertStringSidToSid(string s, out IntPtr sid);
    [DllImport("advapi32.dll")] static extern int GetLengthSid(IntPtr sid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool SetTokenInformation(IntPtr t, int c, ref SA v, int l);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool CreateProcessAsUser(IntPtr t, string app, string cmd, IntPtr a, IntPtr b, bool inh, uint f, IntPtr env, string dir, ref SI si, out PI pi);
    public static int Start(string exe, string cmd) {
        IntPtr own, low, admins, lowSid;
        if (!OpenProcessToken(GetCurrentProcess(), 0x2 | 0x8 | 0x80 | 0x1, out own)) throw new Win32Exception();
        ConvertStringSidToSid("S-1-5-32-544", out admins);
        if (!CreateRestrictedToken(own, 1, 1, new[] { new SA { Sid = admins } }, 0, IntPtr.Zero, 0, IntPtr.Zero, out low)) throw new Win32Exception();
        ConvertStringSidToSid("S-1-16-4096", out lowSid);
        var label = new SA { Sid = lowSid, Attr = 0x20 };
        if (!SetTokenInformation(low, 25, ref label, Marshal.SizeOf(typeof(SA)) + GetLengthSid(lowSid))) throw new Win32Exception();
        var si = new SI { cb = Marshal.SizeOf(typeof(SI)) }; PI pi;
        if (!CreateProcessAsUser(low, exe, "\"" + exe + "\" " + cmd, IntPtr.Zero, IntPtr.Zero, false, 0, IntPtr.Zero, null, ref si, out pi)) throw new Win32Exception();
        return pi.pid;
    }
}
'@
$temp = Join-Path $env:USERPROFILE 'AppData\LocalLow\GpuVM\Viewer\Temp'
$env:TEMP = $temp; $env:TMP = $temp
[Low055]::Start($Exe, $CommandLine)
