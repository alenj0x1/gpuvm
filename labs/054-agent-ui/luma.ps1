# Lab 054 helper: how bright the viewer's picture is on screen right now (0-255, average over a grid of points), to
# tell a real first frame from a black one. Prints "none" when no viewer window is showing.
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace Lab054L -Name W -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
[Lab054L.W]::SetProcessDPIAware() | Out-Null
$p = Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and [Lab054L.W]::IsWindowVisible($_.MainWindowHandle) } | Select-Object -First 1
if (-not $p) { 'none'; exit }
$r = New-Object Lab054L.W+R
[Lab054L.W]::GetWindowRect($p.MainWindowHandle, [ref]$r) | Out-Null
$w = $r.Rt - $r.L; $h = $r.B - $r.T
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
$g.Dispose(); $bmp.Dispose()
[math]::Round($sum / [math]::Max(1, $n), 1)
