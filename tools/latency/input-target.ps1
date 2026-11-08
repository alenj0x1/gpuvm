# Input latency target (Windows PowerShell 5.1 or PowerShell 7). Runs inside the VM in the user's session, or on the
# host as the local reference. A black full-screen window with four squares at mid-height, each switching between
# black and white on its own input:
#   1 key    Scroll Lock pressed
#   2 click  left mouse button pressed
#   3 move   the mouse pointer moved
#   4 pad    button A pressed on any XInput gamepad (Sunshine's virtual Xbox pad needs ViGEmBus in the VM)
# Inputs are polled in a tight loop (not through window messages) and the square is drawn right away, so the target
# adds well under a millisecond plus the next DWM frame. A bar keeps moving along the bottom, so Sunshine streams real
# frames as in a game. tools/latency/input-meter.ps1 measures it. It closes itself after -Minutes.
param([int]$Minutes = 20)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if (-not ('GpuVMInputTarget' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

public class GpuVMInputTarget : Form {
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct XINPUT_STATE { public uint Packet; public ushort Buttons; public byte LeftTrigger, RightTrigger; public short LX, LY, RX, RY; }
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
    [DllImport("xinput1_4.dll")] static extern int XInputGetState(int index, out XINPUT_STATE state);

    // Square i (0-3) is centered at x = (i + 1) / 5 of the width, y = half the height; side = Side of the height.
    public const double Side = 0.18;
    readonly bool[] lit = new bool[4];
    Graphics g;
    bool xinput = true;

    GpuVMInputTarget() {
        FormBorderStyle = FormBorderStyle.None;
        WindowState = FormWindowState.Maximized;
        TopMost = true;
        BackColor = Color.Black;
        ShowInTaskbar = false;
    }

    Rectangle Square(int i) {
        int w = ClientSize.Width, h = ClientSize.Height, side = (int)(h * Side);
        return new Rectangle(w * (i + 1) / 5 - side / 2, h / 2 - side / 2, side, side);
    }

    void DrawSquare(int i) {
        Rectangle r = Square(i);
        g.FillRectangle(lit[i] ? Brushes.White : Brushes.Black, r);
        g.DrawRectangle(Pens.DimGray, r);
    }

    // How many inputs of each kind the target saw, written to %TEMP%\gpuvm-input-target.txt every second, so a miss
    // can be told apart: the input never arrived, or it arrived and the picture didn't show it.
    readonly int[] seen = new int[4];
    public static readonly string StatusPath = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "gpuvm-input-target.txt");

    void Toggle(int i) { lit[i] = !lit[i]; seen[i]++; DrawSquare(i); }

    // Windows repaints the window black after a display mode change (Moonlight sets one at the start of each stream).
    protected override void OnPaint(PaintEventArgs e) {
        if (g == null) return;
        for (int i = 0; i < 4; i++) DrawSquare(i);
    }

    static bool Down(int key) { return (GetAsyncKeyState(key) & 0x8000) != 0; }

    bool PadA() {
        if (!xinput) return false;
        try {
            for (int i = 0; i < 4; i++) {
                XINPUT_STATE s;
                if (XInputGetState(i, out s) == 0 && (s.Buttons & 0x1000) != 0) return true;
            }
        } catch (DllNotFoundException) { xinput = false; }
        return false;
    }

    public static void Run(int minutes) {
        timeBeginPeriod(1);
        var form = new GpuVMInputTarget();
        form.Show();
        form.Activate();
        Application.DoEvents();
        form.g = form.CreateGraphics();
        form.g.Clear(Color.Black);
        for (int i = 0; i < 4; i++) form.DrawSquare(i);
        // The pointer waits in the top-left corner, away from the squares; the meter moves it back and forth.
        SetCursorPos(form.ClientSize.Width / 10, form.ClientSize.Height / 6);

        var clock = Stopwatch.StartNew();
        long deadline = minutes * 60000L, lastBar = -10, lastEvents = 0, lastStatus = 0;
        int barW = 120, barY = form.ClientSize.Height - 80, barX = 0;
        bool keyWas = false, clickWas = false, padWas = false;
        POINT last; GetCursorPos(out last);
        while (form.Visible && clock.ElapsedMilliseconds < deadline) {
            bool key = Down(0x91);
            if (key && !keyWas) form.Toggle(0);
            keyWas = key;
            bool click = Down(0x01);
            if (click && !clickWas) form.Toggle(1);
            clickWas = click;
            POINT p; GetCursorPos(out p);
            if (p.X != last.X || p.Y != last.Y) { form.Toggle(2); last = p; }
            bool pad = form.PadA();
            if (pad && !padWas) form.Toggle(3);
            padWas = pad;

            long now = clock.ElapsedMilliseconds;
            // Moving bar, redrawn every 4 ms: one sweep per second.
            if (now - lastBar >= 4) {
                lastBar = now;
                form.g.FillRectangle(Brushes.Black, barX, barY, barW, 60);
                barX = (int)((now % 1000) / 1000.0 * (form.ClientSize.Width - barW));
                form.g.FillRectangle(Brushes.OrangeRed, barX, barY, barW, 60);
            }
            if (now - lastEvents >= 15) { lastEvents = now; Application.DoEvents(); }
            if (now - lastStatus >= 1000) {
                lastStatus = now;
                try { System.IO.File.WriteAllText(StatusPath, string.Format("key {0} click {1} move {2} pad {3} foreground {4}", form.seen[0], form.seen[1], form.seen[2], form.seen[3], GetForegroundWindow() == form.Handle)); } catch (System.IO.IOException) { }
            }
            Thread.Yield();
        }
        form.g.Dispose();
        form.Close();
    }
}
'@
}
[GpuVMInputTarget]::Run($Minutes)
