# Lab 052: lab 054's luma.ps1, also saving what it measured (-Save file.png).
# Lab 054 helper: how bright the viewer's picture is on screen right now (0-255, average over a grid of points), to
# tell a real first frame from a black one. Prints "none" when no viewer window is showing.
# The viewer is usually embedded in GpuVM's window (--gpuvm-embed): its window is a CHILD of the app's, so the process
# has no MainWindowHandle (lab 054, 2026-11-19: the first version only looked at top-level windows and saw nothing).
param([string]$Save)
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace Lab054L -Name W -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
public delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc f, IntPtr l);
public static System.Collections.Generic.List<IntPtr> Of(uint[] pids) {
    var found = new System.Collections.Generic.List<IntPtr>();
    EnumProc check = (h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (System.Array.IndexOf(pids, p) >= 0 && IsWindowVisible(h)) found.Add(h); return true; };
    EnumWindows((top, l) => { check(top, l); EnumChildWindows(top, check, IntPtr.Zero); return true; }, IntPtr.Zero);
    return found;
}
'@
[Lab054L.W]::SetProcessDPIAware() | Out-Null
$ids = @(Get-Process GpuVMViewer -ErrorAction SilentlyContinue | ForEach-Object { [uint32]$_.Id })
if (-not $ids.Count) { 'none'; exit }
# The largest visible window of a viewer process, top-level or embedded.
$best = $null; $area = 0
foreach ($h in [Lab054L.W]::Of([uint32[]]$ids)) {
    $r = New-Object Lab054L.W+R
    [Lab054L.W]::GetWindowRect($h, [ref]$r) | Out-Null
    $a = ($r.Rt - $r.L) * ($r.B - $r.T)
    if ($a -gt $area) { $area = $a; $best = $r }
}
if (-not $best) { 'none'; exit }
$r = $best; $w = $r.Rt - $r.L; $h = $r.B - $r.T
if ($w -lt 16 -or $h -lt 16) { 'none'; exit }
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
$sum = 0; $n = 0
for ($y = 8; $y -lt $h - 8; $y += [math]::Max(1, [int](($h - 16) / 24))) {
    for ($x = 8; $x -lt $w - 8; $x += [math]::Max(1, [int](($w - 16) / 40))) {
        $c = $bmp.GetPixel($x, $y); $sum += 0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B; $n++
    }
}
if ($Save) { $bmp.Save($Save, [System.Drawing.Imaging.ImageFormat]::Png) }
$g.Dispose(); $bmp.Dispose()
[math]::Round($sum / [math]::Max(1, $n), 1)
