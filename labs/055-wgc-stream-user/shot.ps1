# Lab 055: saves a window's own picture (PrintWindow) and prints how lit it is. Windows PowerShell 5.1 (System.Drawing).
param([long]$Hwnd, [string]$Path)
Add-Type -ReferencedAssemblies System.Drawing @'
using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
public static class Win055 {
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    // The window's own picture; returns the share of pixels that aren't near-black and the brightness spread.
    public static string Shot(IntPtr h, string path) {
        RECT r; GetClientRect(h, out r); int w = r.R - r.L, ht = r.B - r.T; if (w < 10 || ht < 10) return "no-window";
        using (var bmp = new Bitmap(w, ht)) {
            using (var g = Graphics.FromImage(bmp)) { IntPtr dc = g.GetHdc(); PrintWindow(h, dc, 3); g.ReleaseHdc(dc); }
            bmp.Save(path, ImageFormat.Png);
            long lit = 0, n = 0; int min = 255, max = 0;
            for (int y = 0; y < ht; y += 8) for (int x = 0; x < w; x += 8) {
                var c = bmp.GetPixel(x, y); int l = (c.R * 299 + c.G * 587 + c.B * 114) / 1000; n++;
                if (l > 30) lit++; if (l < min) min = l; if (l > max) max = l; }
            return string.Format("lit {0:P0} range {1}-{2}", (double)lit / n, min, max);
        }
    }
}
'@
[Win055]::Shot([IntPtr]$Hwnd, $Path)

