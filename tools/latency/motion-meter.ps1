# Smoothness meter for the bar in motion-target.ps1. Dot-source it, then call Measure-Motion.
# On every host refresh (each GDI read waits for one freshly composed DWM frame, so a read copies a single row: two
# copies would take two refreshes) it finds the bar's left edge on a row near the top of the stream. From the moments
# the bar moves it gets:
#   intervals   time between picture updates; even = smooth, spread = judder
#   stutters    gaps longer than one stream frame plus one host refresh (a frame shown twice or lost)
#   speed       how evenly the bar advances per millisecond between updates
# Tearing can't be measured this way: it happens while the monitor scans the picture out, after composition.
Add-Type -AssemblyName System.Windows.Forms
if (-not ('GpuVMMotionMeter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class GpuVMMotionMeter {
    [StructLayout(LayoutKind.Sequential)] struct BITMAPINFOHEADER {
        public uint biSize; public int biWidth, biHeight; public ushort biPlanes, biBitCount;
        public uint biCompression, biSizeImage; public int biXPelsPerMeter, biYPelsPerMeter; public uint biClrUsed, biClrImportant;
    }
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int w, int h);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr d, int x, int y, int w, int h, IntPtr s, int sx, int sy, uint op);
    [DllImport("gdi32.dll")] static extern int GetDIBits(IntPtr dc, IntPtr bmp, uint start, uint lines, byte[] bits, ref BITMAPINFOHEADER info, uint usage);
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);

    static int Edge(byte[] px, int row, int width) {
        int offset = row * width * 4;
        for (int x = 0; x < width; x++) {
            int i = offset + x * 4;
            if (px[i] + px[i + 1] + px[i + 2] > 384) return x;
        }
        return -1;
    }

    // Returns [ms, edge] for every read during `seconds`; the edge is relative to x0, -1 if not found.
    public static double[] Sample(int x0, int width, int y, double seconds) {
        timeBeginPeriod(1);
        IntPtr screen = GetDC(IntPtr.Zero), mem = CreateCompatibleDC(screen), bmp = CreateCompatibleBitmap(screen, width, 1);
        SelectObject(mem, bmp);
        var info = new BITMAPINFOHEADER { biSize = 40, biWidth = width, biHeight = -1, biPlanes = 1, biBitCount = 32 };
        var px = new byte[width * 4];
        var result = new List<double>();
        var watch = Stopwatch.StartNew();
        while (watch.Elapsed.TotalSeconds < seconds) {
            BitBlt(mem, 0, 0, width, 1, screen, x0, y, 0x00CC0020);
            double t = watch.Elapsed.TotalMilliseconds;
            GetDIBits(mem, bmp, 0, 1, px, ref info, 0);
            result.Add(t); result.Add(Edge(px, 0, width));
        }
        return result.ToArray();
    }
}
'@
}

function Get-MotionPercentile([double[]]$Values, [double]$P) {
    $sorted = $Values | Sort-Object
    $sorted[[math]::Min($sorted.Count - 1, [math]::Max(0, [math]::Ceiling($P * $sorted.Count) - 1))]
}

function Get-MotionStdDev([double[]]$Values) {
    $mean = ($Values | Measure-Object -Average).Average
    [math]::Sqrt((($Values | ForEach-Object { ($_ - $mean) * ($_ - $mean) }) | Measure-Object -Sum).Sum / [math]::Max(1, $Values.Count - 1))
}

# Samples the bar for $Seconds inside $Bounds (the stream's rectangle on this screen) and summarizes it for a stream
# of $Fps frames per second.
function Measure-Motion {
    param(
        [Parameter(Mandatory)][System.Drawing.Rectangle]$Bounds,
        [Parameter(Mandatory)][int]$Fps,
        [double]$Seconds = 20
    )
    $raw = [GpuVMMotionMeter]::Sample($Bounds.Left, $Bounds.Width, $Bounds.Top + [int]($Bounds.Height * 0.1), $Seconds)
    $reads = $raw.Count / 2
    $updates = [System.Collections.Generic.List[double[]]]::new()
    $lastX = -2
    for ($i = 0; $i -lt $reads; $i++) {
        $t = $raw[2 * $i]; $top = $raw[2 * $i + 1]
        if ($top -ge 0 -and $top -ne $lastX) { $updates.Add(@($t, $top)); $lastX = $top }
    }
    $intervals = [System.Collections.Generic.List[double]]::new()
    $speeds = [System.Collections.Generic.List[double]]::new()
    for ($i = 1; $i -lt $updates.Count; $i++) {
        $dt = $updates[$i][0] - $updates[$i - 1][0]
        $dx = $updates[$i][1] - $updates[$i - 1][1]
        if ($dx -le 0) { continue }  # the bar wrapped around to the left edge
        $intervals.Add($dt)
        $speeds.Add($dx / $dt)
    }
    # No bar found or it never moved: the stream showed something else (black, another window).
    if ($intervals.Count -lt 10) {
        return [pscustomobject][ordered]@{ reads = $reads; readsPerSec = [math]::Round($reads / $Seconds, 1); updatesPerSec = 0; error = 'bar not seen' }
    }
    $frameMs = 1000 / $Fps
    # An update can only land on a host refresh, so at rates that don't divide the host's, intervals of one frame plus
    # one host refresh are normal; a stutter is a longer gap than that (and at least 1.5 frames).
    $hostMs = 1000 * $Seconds / [math]::Max(1, $reads)
    $stutterMs = [math]::Max(1.5 * $frameMs, $frameMs + $hostMs + 0.5)
    $meanSpeed = ($speeds | Measure-Object -Average).Average
    [pscustomobject][ordered]@{
        reads = $reads
        readsPerSec = [math]::Round($reads / $Seconds, 1)
        updatesPerSec = [math]::Round($updates.Count / $Seconds, 1)
        intervalMeanMs = [math]::Round(($intervals | Measure-Object -Average).Average, 2)
        intervalSdMs = [math]::Round((Get-MotionStdDev $intervals), 2)
        intervalP99Ms = [math]::Round((Get-MotionPercentile $intervals 0.99), 1)
        stutterPct = [math]::Round(100 * @($intervals | Where-Object { $_ -gt $stutterMs }).Count / [math]::Max(1, $intervals.Count), 2)
        speedCvPct = [math]::Round(100 * (Get-MotionStdDev $speeds) / $meanSpeed, 1)
    }
}
