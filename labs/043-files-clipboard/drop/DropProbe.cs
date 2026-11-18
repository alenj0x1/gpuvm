// Lab 043 (drop): can a file dragged from a normal (Medium) program reach the viewer's Low-integrity, restricted
// window, and can the app's own window take over the drop once the viewer says a drag is over it?
//   DropProbe launch <Low|Medium> <exe> <args...>   start a process with a restricted token (Administrators
//                                                   deny-only, no privileges) at that integrity level, in a job
//   DropProbe target <statusDir>                    the "viewer": a top-most window that accepts drops (OLE)
//   DropProbe overlay <statusDir>                   the "app": shows its own drop window over the target when
//                                                   the target reports a drag
//   DropProbe source <statusDir> <file> [overlay]   a Medium drag source: moves the cursor onto the target and
//                                                   drops <file> there (only if one of our windows is under it)
// Every side writes what it saw to <statusDir>\<role>.log.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

// Shown without taking the focus: activating a window in the middle of a drag makes OLE cancel it.
class QuietForm : Form
{
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams { get { var p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x8; return p; } }
}

static class P
{
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    static string dir;
    static string role;
    static void Log(string s)
    {
        File.AppendAllText(Path.Combine(dir, role + ".log"), DateTime.Now.ToString("HH:mm:ss.fff") + " " + s + Environment.NewLine);
    }

    [STAThread]
    static int Main(string[] a)
    {
        role = a[0];
        if (role == "launch") { try { return Launch(a); } catch (Exception e) { File.AppendAllText(Path.Combine(Path.GetDirectoryName(a[2]), "launch.err"), e.Message + Environment.NewLine); return 3; } }
        dir = a[1];
        Directory.CreateDirectory(dir);
        try
        {
            Log("start il=" + Integrity());
            if (role == "target") return Target(a.Length > 2 && a[2] == "accept");
            if (role == "overlay") return Overlay();
            if (role == "source") return Source(a[2], a.Length > 3 && a[3] == "overlay");
        }
        catch (Exception e) { Log("error " + e); return 2; }
        return 1;
    }

    // ------------------------------------------------------------- target (viewer stand-in)
    static int Target(bool accept)
    {
        var f = new Form { Text = "lab043-target", TopMost = true, StartPosition = FormStartPosition.Manual, Bounds = new Rectangle(200, 200, 640, 360), BackColor = Color.FromArgb(40, 40, 40), AllowDrop = true, ShowInTaskbar = false };
        f.DragEnter += (s, e) => { Log("enter formats=" + string.Join(",", e.Data.GetFormats())); e.Effect = accept ? DragDropEffects.Copy : DragDropEffects.None; File.WriteAllText(Path.Combine(dir, "drag.flag"), "1"); };
        int overs = 0; f.DragOver += (s, e) => { e.Effect = accept ? DragDropEffects.Copy : DragDropEffects.None; if (overs++ % 10 == 0) Log("over n=" + overs + " allowed=" + e.AllowedEffect + " effect=" + e.Effect + " keys=" + e.KeyState); };
        f.DragLeave += (s, e) => Log("leave");
        f.DragDrop += (s, e) =>
        {
            var files = e.Data.GetData(DataFormats.FileDrop) as string[];
            Log("drop " + (files == null ? "(none)" : string.Join("|", files)));
        };
        f.Shown += (s, e) => File.WriteAllText(Path.Combine(dir, "target.hwnd"), f.Handle.ToInt64().ToString());
        var t = new System.Windows.Forms.Timer { Interval = 20000 };
        t.Tick += (s, e) => f.Close();
        t.Start();
        Application.Run(f);
        return 0;
    }

    // ------------------------------------------------------------- overlay (app stand-in)
    static int Overlay()
    {
        var f = new QuietForm { Text = "lab043-overlay", TopMost = true, FormBorderStyle = FormBorderStyle.None, StartPosition = FormStartPosition.Manual, Bounds = new Rectangle(200, 200, 640, 360), BackColor = Color.FromArgb(60, 90, 160), Opacity = 0.85, AllowDrop = true, ShowInTaskbar = false };
        f.DragEnter += (s, e) => { Log("enter"); e.Effect = DragDropEffects.Copy; };
        f.DragOver += (s, e) => e.Effect = DragDropEffects.Copy;
        f.DragLeave += (s, e) => { Log("leave"); f.Hide(); };
        f.DragDrop += (s, e) =>
        {
            var files = e.Data.GetData(DataFormats.FileDrop) as string[];
            Log("drop " + (files == null ? "(none)" : string.Join("|", files)));
            f.Hide();
        };
        var flag = Path.Combine(dir, "drag.flag");
        var poll = new System.Windows.Forms.Timer { Interval = 15 };
        poll.Tick += (s, e) =>
        {
            if (File.Exists(flag)) { File.Delete(flag); Log("shown"); SetWindowPos(f.Handle, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 | 0x0040); File.WriteAllText(Path.Combine(dir, "overlay.hwnd"), f.Handle.ToInt64().ToString()); }
        };
        poll.Start();
        var end = new System.Windows.Forms.Timer { Interval = 20000 };
        end.Tick += (s, e) => Application.Exit();
        end.Start();
        Application.Run(new ApplicationContext());
        return 0;
    }

    // ------------------------------------------------------------- source (Explorer stand-in)
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);

    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy, data, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public int type; public MOUSEINPUT mi; }
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    static void Mouse(int flags, Point? at = null)
    {
        var mi = new MOUSEINPUT { flags = flags };
        if (at.HasValue)
        {
            var b = SystemInformation.VirtualScreen;
            mi.dx = (int)((at.Value.X - b.Left) * 65535.0 / (b.Width - 1));
            mi.dy = (int)((at.Value.Y - b.Top) * 65535.0 / (b.Height - 1));
            mi.flags |= 0x0001 | 0x8000 | 0x4000; // MOVE | ABSOLUTE | VIRTUALDESK
        }
        SendInput(1, new[] { new INPUT { type = 0, mi = mi } }, Marshal.SizeOf(typeof(INPUT)));
    }

    // Like a person: the button goes down on our own small window (left of the target), the pointer moves onto
    // the target and the button goes up there. The drag is cancelled if anything that isn't ours is under it.
    static int Source(string file, bool expectOverlay)
    {
        var hwndPath = Path.Combine(dir, "target.hwnd");
        for (int i = 0; i < 100 && !File.Exists(hwndPath); i++) Thread.Sleep(100);
        var target = new IntPtr(long.Parse(File.ReadAllText(hwndPath)));
        var ours = new HashSet<IntPtr> { target };
        var form = new Form { ShowInTaskbar = false, TopMost = true, FormBorderStyle = FormBorderStyle.None, StartPosition = FormStartPosition.Manual, Bounds = new Rectangle(130, 360, 40, 40), BackColor = Color.Orange };
        var start = new Point(150, 380);
        var end = new Point(520, 380);
        var watch = Stopwatch.StartNew();
        string outcome = "?";
        bool released = false;
        form.MouseDown += (s, e) =>
        {
            Log("mousedown");
            var data = new DataObject(DataFormats.FileDrop, new[] { file });
            form.QueryContinueDrag += (o, q) =>
            {
                if (File.Exists(Path.Combine(dir, "overlay.hwnd"))) ours.Add(new IntPtr(long.Parse(File.ReadAllText(Path.Combine(dir, "overlay.hwnd")))));
                var p = Cursor.Position;
                var under = GetAncestor(WindowFromPoint(p), 2);
                if (p.X > 200 && under != form.Handle && !ours.Contains(under)) { q.Action = DragAction.Cancel; outcome = "cancel: not ours under pointer"; return; }
                if ((q.KeyState & 1) == 0) { q.Action = DragAction.Drop; outcome = "drop over " + (under == target ? "target" : "overlay"); }
            };
            var mover = new Thread(() =>
            {
                try
                {
                    for (int i = 0; i <= 40; i++) { Mouse(0, new Point(start.X + i * (end.X - start.X) / 40, end.Y)); Thread.Sleep(15); }
                    // Hover a moment (the app's own window may take over the target here), then let go.
                    for (int i = 0; i < 60; i++) { Mouse(0, new Point(end.X + i % 2, end.Y)); Thread.Sleep(15); }
                }
                finally { Mouse(0x0004); released = true; }
            });
            mover.IsBackground = true;
            mover.Start();
            var r = form.DoDragDrop(data, DragDropEffects.Copy);
            Log("done " + outcome + " effect=" + r + " ms=" + watch.ElapsedMilliseconds);
            form.Close();
        };
        form.Shown += (s, e) =>
        {
            var t = new System.Windows.Forms.Timer { Interval = 300 };
            t.Tick += (o, x) => { t.Stop(); Mouse(0, start); Thread.Sleep(30); Mouse(0x0002); };
            t.Start();
        };
        try { Application.Run(form); }
        finally { if (!released) Mouse(0x0004); }
        return 0;
    }
    // ------------------------------------------------------------- integrity / launcher
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr t);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetTokenInformation(IntPtr t, int cls, IntPtr buf, int len, out int ret);
    [DllImport("advapi32.dll", SetLastError = true)] static extern IntPtr GetSidSubAuthority(IntPtr sid, uint i);
    [DllImport("advapi32.dll", SetLastError = true)] static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();

    static string Integrity()
    {
        IntPtr t; OpenProcessToken(GetCurrentProcess(), 8, out t);
        int n; GetTokenInformation(t, 25, IntPtr.Zero, 0, out n);
        var buf = Marshal.AllocHGlobal(n);
        GetTokenInformation(t, 25, buf, n, out n);
        var sid = Marshal.ReadIntPtr(buf);
        int count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
        return "0x" + Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(count - 1))).ToString("x");
    }

    [StructLayout(LayoutKind.Sequential)] struct SID_AND_ATTRIBUTES { public IntPtr Sid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)] struct TOKEN_MANDATORY_LABEL { public SID_AND_ATTRIBUTES Label; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO { public int cb; public string r, desk, title; public int x, y, w, h, cx, cy, fill, flags; public short show, r2; public IntPtr r3, i, o, e; }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int pid, tid; }
    [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_BASIC_UI_RESTRICTIONS { public uint UIRestrictionsClass; }

    [DllImport("advapi32.dll", SetLastError = true)] static extern bool CreateRestrictedToken(IntPtr t, uint flags, uint nDisable, SID_AND_ATTRIBUTES[] disable, uint nDel, IntPtr del, uint nRestrict, IntPtr restrict, out IntPtr n);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool ConvertStringSidToSid(string s, out IntPtr sid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern int GetLengthSid(IntPtr sid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool SetTokenInformation(IntPtr t, int cls, ref TOKEN_MANDATORY_LABEL l, int len);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool CreateProcessAsUser(IntPtr t, string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr a, string n);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr j, int cls, ref JOBOBJECT_BASIC_UI_RESTRICTIONS i, int len);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint ResumeThread(IntPtr t);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr h, uint ms);

    [DllImport("advapi32.dll", SetLastError = true)] static extern bool DuplicateTokenEx(IntPtr t, uint access, IntPtr sa, int imp, int type, out IntPtr n);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool CreateProcessWithTokenW(IntPtr t, int logon, string app, string cmd, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);

    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

    // The person's own unelevated token: Explorer's (the linked token of an elevated one is only good for
    // identification without SeTcbPrivilege).
    static IntPtr UserToken()
    {
        var explorer = Process.GetProcessesByName("explorer")[0];
        var h = OpenProcess(0x1000, false, explorer.Id);
        IntPtr t; if (!OpenProcessToken(h, 0x0002 | 0x0008, out t)) throw new Exception("explorer token " + Marshal.GetLastWin32Error());
        IntPtr primary; if (!DuplicateTokenEx(t, 0x000F01FF, IntPtr.Zero, 2, 1, out primary)) throw new Exception("dup " + Marshal.GetLastWin32Error());
        return primary;
    }
    //   launch Medium  -> the person's normal unelevated token (Explorer, the GpuVM app)
    //   launch Low     -> the viewer: that token restricted like the app's lowbox.rs (Administrators deny-only,
    //                     no privileges, Low label) inside a job with the same UI limits
    static int Launch(string[] a)
    {
        var user = UserToken();
        var token = user;
        IntPtr job = IntPtr.Zero;
        if (a[1] == "Low")
        {
            IntPtr admins; ConvertStringSidToSid("S-1-5-32-544", out admins);
            if (!CreateRestrictedToken(user, 1, 1, new[] { new SID_AND_ATTRIBUTES { Sid = admins } }, 0, IntPtr.Zero, 0, IntPtr.Zero, out token)) throw new Exception("restricted " + Marshal.GetLastWin32Error());
            IntPtr il; ConvertStringSidToSid("S-1-16-4096", out il);
            var label = new TOKEN_MANDATORY_LABEL { Label = new SID_AND_ATTRIBUTES { Sid = il, Attributes = 0x20 } };
            if (!SetTokenInformation(token, 25, ref label, Marshal.SizeOf(label) + GetLengthSid(il))) throw new Exception("label " + Marshal.GetLastWin32Error());
            job = CreateJobObject(IntPtr.Zero, null);
            var ui = new JOBOBJECT_BASIC_UI_RESTRICTIONS { UIRestrictionsClass = 0x40 | 0x80 | 0x08 | 0x10 | 0x04 };
            SetInformationJobObject(job, 4, ref ui, 4);
        }
        var cmd = "\"" + a[2] + "\"";
        for (int i = 3; i < a.Length; i++) cmd += " \"" + a[i] + "\"";
        var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si);
        PROCESS_INFORMATION pi;
        if (!CreateProcessWithTokenW(token, 0, a[2], cmd, 0x4 | 0x400, IntPtr.Zero, null, ref si, out pi)) throw new Exception("create " + Marshal.GetLastWin32Error());
        if (job != IntPtr.Zero) AssignProcessToJobObject(job, pi.hProcess);
        ResumeThread(pi.hThread);
        WaitForSingleObject(pi.hProcess, 30000);
        return 0;
    }
}
