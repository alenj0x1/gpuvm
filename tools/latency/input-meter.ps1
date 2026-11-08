# Input latency meter for the target in input-target.ps1. Dot-source it, then call Measure-InputLatency.
# For each sample it injects one input with SendInput (or, for the gamepad, waits for a real press on an XInput pad
# connected to this PC), then reads the matching square on this screen until it flips between black and white.
# Screen reads go through GDI, which hands back a freshly composed DWM frame on every read: the time resolution is
# one host refresh (5.6 ms at 180 Hz). The monitor's own scan-out and pixel response are not included.
# The pad's own USB polling is included, as in a game on this PC.
Add-Type -AssemblyName System.Windows.Forms
if (-not ('GpuVMInputMeter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

public static class GpuVMInputMeter {
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit)] struct UNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public UNION u; }
    [StructLayout(LayoutKind.Sequential)] struct XINPUT_STATE { public uint Packet; public ushort Buttons; public byte LeftTrigger, RightTrigger; public short LX, LY, RX, RY; }
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int w, int h);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr d, int x, int y, int w, int h, IntPtr s, int sx, int sy, uint op);
    [DllImport("gdi32.dll")] static extern uint GetPixel(IntPtr dc, int x, int y);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);

    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);

    // Windows refuses SetForegroundWindow to a process that didn't get the last input; an Alt tap from this process
    // lifts that lock. Without it the elevated console stays in front of Moonlight and the inputs never reach the VM.
    public static bool BringToFront(IntPtr h) {
        for (int i = 0; i < 5 && GetForegroundWindow() != h; i++) {
            var alt = new INPUT { type = 1 };
            alt.u.ki = new KEYBDINPUT { wVk = 0x12 };
            Send(alt);
            alt.u.ki.dwFlags = 2;
            Send(alt);
            ShowWindow(h, 9);
            SetForegroundWindow(h);
            Thread.Sleep(200);
        }
        return GetForegroundWindow() == h;
    }

    // Screen rectangle of a window's client area: left, top, width, height.
    public static int[] ClientBounds(IntPtr h) {
        RECT r; GetClientRect(h, out r);
        var p = new POINT();
        ClientToScreen(h, ref p);
        return new[] { p.X, p.Y, r.Right - r.Left, r.Bottom - r.Top };
    }
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
    [DllImport("xinput1_4.dll")] static extern int XInputGetState(int index, out XINPUT_STATE state);

    static IntPtr screen, mem;
    static int sign = 1;

    static void Init() {
        if (screen != IntPtr.Zero) return;
        timeBeginPeriod(1);
        screen = GetDC(IntPtr.Zero);
        mem = CreateCompatibleDC(screen);
        SelectObject(mem, CreateCompatibleBitmap(screen, 1, 1));
    }

    // Brightness 0-255 of one screen pixel, from the latest composed frame.
    public static int Brightness(int x, int y) {
        Init();
        BitBlt(mem, 0, 0, 1, 1, screen, x, y, 0x00CC0020);
        uint c = GetPixel(mem, 0, 0);
        return (int)(((c & 0xFF) + ((c >> 8) & 0xFF) + ((c >> 16) & 0xFF)) / 3);
    }

    static void Send(INPUT input) { SendInput(1, new[] { input }, Marshal.SizeOf(typeof(INPUT))); }

    // Scroll Lock by virtual key and scan code (Moonlight reads scan codes).
    static void Key(bool down) {
        var i = new INPUT { type = 1 };
        i.u.ki = new KEYBDINPUT { wVk = 0x91, wScan = 0x46, dwFlags = down ? 0u : 2u };
        Send(i);
    }

    static void Mouse(uint flags, int dx) {
        var i = new INPUT { type = 0 };
        i.u.mi = new MOUSEINPUT { dx = dx, dwFlags = flags };
        Send(i);
    }

    // kind: 0 key, 1 click, 2 move. Returns the milliseconds from the injection until the square at (x, y) flips;
    // -1 on timeout. With a window, nothing is injected unless that window is in front (-3): otherwise the
    // clicks, keys and moves would land on whatever else is open on this PC.
    public static double Measure(int kind, int x, int y, int timeoutMs, IntPtr window) {
        if (window != IntPtr.Zero && GetForegroundWindow() != window) return -3;
        bool wasLit = Brightness(x, y) > 128;
        var watch = Stopwatch.StartNew();
        if (kind == 0) Key(true);
        else if (kind == 1) Mouse(0x0002, 0);
        else { Mouse(0x0001, 40 * sign); sign = -sign; }
        double result = -1;
        while (watch.ElapsedMilliseconds < timeoutMs) {
            if ((Brightness(x, y) > 128) != wasLit) { result = watch.Elapsed.TotalMilliseconds; break; }
        }
        if (kind == 0) Key(false);
        else if (kind == 1) Mouse(0x0004, 0);
        return result;
    }

    static bool PadA() {
        for (int i = 0; i < 4; i++) {
            XINPUT_STATE s;
            if (XInputGetState(i, out s) == 0 && (s.Buttons & 0x1000) != 0) return true;
        }
        return false;
    }

    // Waits up to waitMs for a real press of A on a pad connected to this PC, then times until the square flips.
    // -2 when nobody pressed, -1 when the square did not flip within timeoutMs.
    public static double MeasurePad(int x, int y, int waitMs, int timeoutMs) {
        Init();
        var wait = Stopwatch.StartNew();
        while (PadA()) { if (wait.ElapsedMilliseconds > waitMs) return -2; Thread.Sleep(1); }
        bool wasLit = Brightness(x, y) > 128;
        while (!PadA()) { if (wait.ElapsedMilliseconds > waitMs) return -2; Thread.SpinWait(200); }
        var watch = Stopwatch.StartNew();
        while (watch.ElapsedMilliseconds < timeoutMs) {
            if ((Brightness(x, y) > 128) != wasLit) return watch.Elapsed.TotalMilliseconds;
        }
        return -1;
    }
}
'@
}

# Small always-on-top box in the top-left corner that tells the person when to press A and how many presses are left.
# It never takes the focus or the clicks (Moonlight keeps them) and stays away from the squares the meter reads.
if (-not ('GpuVMPadPrompt' -as [type])) {
    # PowerShell 7 needs the assemblies .NET split WinForms into.
    $refs = 'System.Windows.Forms', 'System.Drawing'
    if ($PSVersionTable.PSEdition -eq 'Core') { $refs += 'System.ComponentModel.Primitives', 'System.Drawing.Primitives', 'System.Drawing.Common', 'System.Threading.Thread', 'System.Threading', 'System.Windows.Forms.Primitives', 'System.Private.Windows.Core' }
    Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System;
using System.Drawing;
using System.Threading;
using System.Windows.Forms;

public class GpuVMPadPrompt : Form {
    static GpuVMPadPrompt current;
    readonly Label text = new Label();

    GpuVMPadPrompt() {
        FormBorderStyle = FormBorderStyle.None;
        TopMost = true;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        Location = new Point(24, 24);
        Size = new Size(460, 110);
        BackColor = Color.White;
        text.Dock = DockStyle.Fill;
        text.TextAlign = ContentAlignment.MiddleCenter;
        text.Font = new Font("Segoe UI", 22, FontStyle.Bold);
        text.ForeColor = Color.Black;
        Controls.Add(text);
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams {
        get {
            var p = base.CreateParams;
            p.ExStyle |= 0x08000000 | 0x00000020 | 0x00080000 | 0x00000008; // NOACTIVATE, TRANSPARENT, LAYERED, TOPMOST
            return p;
        }
    }

    public static void Open(string message) {
        var ready = new ManualResetEvent(false);
        var thread = new Thread(() => {
            current = new GpuVMPadPrompt();
            current.text.Text = message;
            current.Opacity = 0.95;
            current.Show();
            ready.Set();
            Application.Run(current);
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
        ready.WaitOne();
    }

    public static void Say(string message) {
        var f = current;
        if (f != null) f.BeginInvoke((Action)(() => { f.text.Text = message; }));
    }

    public static void Close2() {
        var f = current;
        current = null;
        if (f != null) f.BeginInvoke((Action)(() => f.Close()));
    }
}
'@
}

function Get-InputPercentile([double[]]$Values, [double]$P) {
    $sorted = $Values | Sort-Object
    $index = [math]::Min($sorted.Count - 1, [math]::Max(0, [math]::Ceiling($P * $sorted.Count) - 1))
    [math]::Round($sorted[$index], 1)
}

# Screen point at the center of square $Index (0 key, 1 click, 2 move, 3 pad) of a target filling $Bounds.
function Get-InputSquarePoint {
    param([Parameter(Mandatory)][System.Drawing.Rectangle]$Bounds, [Parameter(Mandatory)][int]$Index)
    [pscustomobject]@{ X = $Bounds.Left + [int]($Bounds.Width * ($Index + 1) / 5); Y = $Bounds.Top + [int]($Bounds.Height / 2) }
}

# Runs $Samples samples of each kind in $Kinds (key, click, move, pad) and returns one summary per kind.
# Pauses between samples are random (150-400 ms) so the injections don't line up with any frame clock.
function Measure-InputLatency {
    param(
        [Parameter(Mandatory)][System.Drawing.Rectangle]$Bounds,
        [string[]]$Kinds = @('key', 'click', 'move'),
        [int]$Samples = 60,
        [int]$TimeoutMs = 500,
        [int]$PadWaitSec = 120,
        # Moonlight's window: samples are only taken while it is in front, and the run stops if it can't be brought back.
        [IntPtr]$Window = [IntPtr]::Zero
    )
    $assertFront = {
        if ($Window -ne [IntPtr]::Zero -and -not [GpuVMInputMeter]::BringToFront($Window)) {
            throw 'Moonlight is no longer in front: stopped so no input lands on this PC.'
        }
    }
    $index = @{ key = 0; click = 1; move = 2; pad = 3 }
    $random = [System.Random]::new()
    foreach ($kind in $Kinds) {
        $point = Get-InputSquarePoint -Bounds $Bounds -Index $index[$kind]
        $times = [System.Collections.Generic.List[double]]::new()
        $misses = 0
        & $assertFront
        if ($kind -eq 'pad') {
            [GpuVMPadPrompt]::Open("Presiona A  -  0 / $Samples")
            [console]::Beep(880, 250)
        }
        for ($i = 0; $i -lt $Samples; $i++) {
            $ms = if ($kind -eq 'pad') { [GpuVMInputMeter]::MeasurePad($point.X, $point.Y, $PadWaitSec * 1000, $TimeoutMs) }
                  else { [GpuVMInputMeter]::Measure($index[$kind], $point.X, $point.Y, $TimeoutMs, $Window) }
            if ($ms -eq -2) { break }
            if ($ms -eq -3) { & $assertFront; $i--; continue }
            if ($ms -lt 0) { $misses++ } else { $times.Add($ms) }
            if ($kind -eq 'pad') { [GpuVMPadPrompt]::Say("Presiona A  -  $($i + 1) / $Samples") }
            # Let the square settle on the next frames before the next sample. Not for the pad: a person's presses
            # are already irregular, and a press during the pause would go uncounted.
            if ($kind -ne 'pad') { Start-Sleep -Milliseconds (150 + $random.Next(0, 250)) }
        }
        if ($kind -eq 'pad') {
            [GpuVMPadPrompt]::Say('Listo, suelta el mando')
            [console]::Beep(660, 150); [console]::Beep(990, 250)
            Start-Sleep -Milliseconds 1200
            [GpuVMPadPrompt]::Close2()
        }
        $row = [ordered]@{ kind = $kind; samples = $times.Count; misses = $misses }
        if ($times.Count) {
            $row.minMs = [math]::Round(($times | Measure-Object -Minimum).Minimum, 1)
            $row.meanMs = [math]::Round(($times | Measure-Object -Average).Average, 1)
            $row.medianMs = Get-InputPercentile $times 0.5
            $row.p95Ms = Get-InputPercentile $times 0.95
            $row.maxMs = [math]::Round(($times | Measure-Object -Maximum).Maximum, 1)
        }
        $row.raw = @($times | ForEach-Object { [math]::Round($_, 2) })
        [pscustomobject]$row
    }
}
