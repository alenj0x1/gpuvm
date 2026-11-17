# Lab 039 helper: looks at and drives the real GpuVM window like a person would (screen captures and clicks), to
# watch the viewer's open/close transitions. Nothing here changes settings; it only captures and clicks.
#   screen.ps1 shot  -Out x.png [-Scale 0.5]
#   screen.ps1 click -X 100 -Y 200
#   screen.ps1 keys  -Keys '^%+g'             (SendKeys syntax, to the foreground window)
#   screen.ps1 film  -Out dir -Seconds 12 -Fps 12 [-Scale 0.4]
#   screen.ps1 window                         (GpuVM's window rectangle)
param(
    [Parameter(Mandatory)][ValidateSet('shot', 'click', 'keys', 'film', 'window')][string]$Action,
    [string]$Out, [double]$Scale = 0.5, [int]$X, [int]$Y, [string]$Keys, [int]$Seconds = 10, [int]$Fps = 10
)
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -Namespace Lab -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, System.UIntPtr e);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int c);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(System.IntPtr h, out int pid);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, System.IntPtr l);
// The app's main window: restores its minimized windows, then the largest visible one (not the panel or tray).
public static System.IntPtr Main(int pid) {
    EnumWindows((h, l) => { int p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h) && IsIconic(h)) ShowWindow(h, 9); return true; }, System.IntPtr.Zero);
    System.Threading.Thread.Sleep(300);
    System.IntPtr best = System.IntPtr.Zero; long area = 0;
    EnumWindows((h, l) => { int p; GetWindowThreadProcessId(h, out p); RECT r;
        if (p == pid && IsWindowVisible(h) && GetWindowRect(h, out r)) { long a = (long)(r.Right - r.Left) * (r.Bottom - r.Top); if (a > area) { area = a; best = h; } }
        return true; }, System.IntPtr.Zero);
    return best;
}
public struct RECT { public int Left, Top, Right, Bottom; }
'@
[Lab.Native]::SetProcessDPIAware() | Out-Null
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

function Save-Shot([string]$path, [double]$scale) {
    $bmp = [System.Drawing.Bitmap]::new($screen.Width, $screen.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($screen.X, $screen.Y, 0, 0, $bmp.Size)
    $w = [int]($screen.Width * $scale); $h = [int]($screen.Height * $scale)
    $small = [System.Drawing.Bitmap]::new($bmp, $w, $h)
    $small.Save($path, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $small.Dispose(); $g.Dispose(); $bmp.Dispose()
}

switch ($Action) {
    'shot' { Save-Shot $Out $Scale; "screen $($screen.Width)x$($screen.Height) saved at scale $Scale" }
    'click' {
        [Lab.Native]::SetCursorPos($X, $Y) | Out-Null
        Start-Sleep -Milliseconds 80
        [Lab.Native]::mouse_event(0x2, 0, 0, 0, [UIntPtr]::Zero)
        [Lab.Native]::mouse_event(0x4, 0, 0, 0, [UIntPtr]::Zero)
        "clicked $X,$Y"
    }
    'keys' { [System.Windows.Forms.SendKeys]::SendWait($Keys); "sent" }
    'window' {
        $p = Get-Process gpuvm -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $p) { 'no window'; return }
        $h = [Lab.Native]::Main($p.Id)
        $r = New-Object Lab.Native+RECT
        [Lab.Native]::GetWindowRect($h, [ref]$r) | Out-Null
        # Windows only lets the process with the last input change the foreground: an Alt tap lifts that lock.
        [Lab.Native]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [Lab.Native]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
        [Lab.Native]::SetForegroundWindow($h) | Out-Null
        Start-Sleep -Milliseconds 300
        if ([Lab.Native]::GetForegroundWindow() -ne $h) { 'not in front'; return }
        "$($r.Left),$($r.Top),$($r.Right),$($r.Bottom)"
    }
    'film' {
        New-Item -ItemType Directory -Force -Path $Out | Out-Null
        $frames = $Seconds * $Fps
        $sw = [Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt $frames; $i++) {
            Save-Shot (Join-Path $Out ('{0:D4}-{1}ms.jpg' -f $i, $sw.ElapsedMilliseconds)) $Scale
            $next = ($i + 1) * 1000 / $Fps
            $wait = $next - $sw.ElapsedMilliseconds
            if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
        }
        "frames: $frames in $($sw.ElapsedMilliseconds) ms"
    }
}
