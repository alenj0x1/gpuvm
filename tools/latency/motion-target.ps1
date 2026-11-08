# Smoothness target (Windows PowerShell 5.1 or PowerShell 7). Runs inside the VM in the user's session.
# A white bar the full height of the screen crosses a black background at a constant speed (one width every
# -SweepSec seconds), redrawn as fast as the loop runs from a high-resolution clock, so any unevenness on the host
# comes from the stream, not from the target. tools/latency/motion-meter.ps1 measures it. Closes after -Minutes.
# -Windowed: a normal window over 70 % of the screen instead of a full-screen one (DDX capture treats full-screen
# windows differently).
param([int]$Minutes = 20, [double]$SweepSec = 2, [switch]$Windowed)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if (-not ('GpuVMMotionTarget' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

public class GpuVMMotionTarget : Form {
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    public const int BarWidth = 40;

    static bool windowed;

    GpuVMMotionTarget() {
        FormBorderStyle = FormBorderStyle.None;
        TopMost = !windowed;
        if (windowed) {
            var area = Screen.PrimaryScreen.Bounds;
            StartPosition = FormStartPosition.Manual;
            Bounds = new Rectangle(area.Width * 15 / 100, area.Height * 15 / 100, area.Width * 70 / 100, area.Height * 70 / 100);
        } else {
            WindowState = FormWindowState.Maximized;
        }
        BackColor = Color.Black;
        ShowInTaskbar = false;
        Cursor.Hide();
    }

    public static void Run(int minutes, double sweepSec, bool inWindow) {
        windowed = inWindow;
        timeBeginPeriod(1);
        var form = new GpuVMMotionTarget();
        form.Show();
        form.Activate();
        Application.DoEvents();
        int w = form.ClientSize.Width, h = form.ClientSize.Height;
        SetCursorPos(w - 1, h - 1);
        Graphics g = form.CreateGraphics();
        g.Clear(Color.Black);
        var clock = Stopwatch.StartNew();
        long deadline = minutes * 60000L, lastEvents = 0, lastRefresh = 0, drawn = 0;
        int x = 0;
        string status = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "gpuvm-motion-target.txt");
        while (form.Visible && clock.ElapsedMilliseconds < deadline) {
            // A display mode change (each stream can set one) leaves the window's drawing surface stale: drawing on it
            // shows nothing. Take a new one, and the full size, twice a second.
            if (clock.ElapsedMilliseconds - lastRefresh >= 500) {
                lastRefresh = clock.ElapsedMilliseconds;
                if (form.ClientSize.Width != w || form.ClientSize.Height != h) { w = form.ClientSize.Width; h = form.ClientSize.Height; }
                g.Dispose();
                g = form.CreateGraphics();
                form.TopMost = !windowed;
                try { System.IO.File.WriteAllText(status, string.Format("{0:O} drawn {1} size {2}x{3}", DateTime.Now, drawn, w, h)); } catch (System.IO.IOException) { }
            }
            double t = clock.Elapsed.TotalSeconds;
            int nx = (int)((t % sweepSec) / sweepSec * (w - BarWidth));
            // New bar first, then only the strip it left behind: erasing first would let a capture catch a frame
            // with no bar at all.
            if (nx != x) {
                g.FillRectangle(Brushes.White, nx, 0, BarWidth, h);
                if (nx > x && nx < x + BarWidth) g.FillRectangle(Brushes.Black, x, 0, nx - x, h);
                else g.FillRectangle(Brushes.Black, x, 0, BarWidth, h);
                x = nx;
                drawn++;
            }
            long now = clock.ElapsedMilliseconds;
            if (now - lastEvents >= 15) { lastEvents = now; Application.DoEvents(); }
            Thread.Yield();
        }
        g.Dispose();
        form.Close();
    }
}
'@
}
[GpuVMMotionTarget]::Run($Minutes, $SweepSec, $Windowed.IsPresent)
