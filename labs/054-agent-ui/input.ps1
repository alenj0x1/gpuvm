# Lab 054 helper: the person's mouse moving over the viewer's picture, without touching the real cursor: two
# WM_MOUSEMOVE messages posted to the viewer's window (SDL turns them into motion events, as for a real move).
# Prints the Unix ms of the first one, so take-control.mjs can measure input → agent paused.
#   pwsh -NoProfile -File input.ps1            (the largest visible GpuVMViewer window, top-level or embedded)
# The viewer is usually embedded in GpuVM's window (a child window, no MainWindowHandle): the first version only
# looked at top-level windows and its moves never reached the picture (lab 054, 2026-11-19).
# The second move ends where the real cursor is: SDL then remembers the real position, and a move Windows sends by
# itself later (a window appearing over a still cursor) has no distance, as with a real person. Ending elsewhere made
# those count as the person's input and paused the agent between rounds (2026-11-19, round 2 missed).
Add-Type -Namespace Lab054 -Name Win -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; }
[StructLayout(LayoutKind.Sequential)] public struct P { public int X, Y; }
[DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out P p);
[DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref P p);
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
[Lab054.Win]::SetProcessDPIAware() | Out-Null
$ids = @(Get-Process GpuVMViewer -ErrorAction SilentlyContinue | ForEach-Object { [uint32]$_.Id })
if (-not $ids.Count) { 'no-viewer'; exit 1 }
$h = [IntPtr]::Zero; $area = 0
foreach ($w in [Lab054.Win]::Of([uint32[]]$ids)) {
    $r = New-Object Lab054.Win+R
    [Lab054.Win]::GetWindowRect($w, [ref]$r) | Out-Null
    $a = ($r.Rt - $r.L) * ($r.B - $r.T)
    if ($a -gt $area) { $area = $a; $h = $w }
}
if ($h -eq [IntPtr]::Zero) { 'no-viewer'; exit 1 }
$c = New-Object Lab054.Win+P
[Lab054.Win]::GetCursorPos([ref]$c) | Out-Null
[Lab054.Win]::ScreenToClient($h, [ref]$c) | Out-Null
# SDL drops a move whose point is outside its window (the mouse isn't "in" it), so with the real cursor elsewhere
# (2026-11-19: 0 of 10 rounds) both moves stay inside the picture; Windows sends that window no moves of its own then.
$wr = New-Object Lab054.Win+R
[Lab054.Win]::GetWindowRect($h, [ref]$wr) | Out-Null
$cw = $wr.Rt - $wr.L; $ch = $wr.B - $wr.T
if ($c.X -lt 40 -or $c.Y -lt 40 -or $c.X -gt $cw - 40 -or $c.Y -gt $ch - 40) {
    $c.X = [int]($cw / 2) + (Get-Random -Maximum 60); $c.Y = [int]($ch / 2) + (Get-Random -Maximum 60)
}
$WM_MOUSEMOVE = 0x0200
# Client coordinates as Windows packs them: two signed 16-bit halves.
$pos = { param($x, $y) [IntPtr]((($y -band 0xFFFF) -shl 16) -bor ($x -band 0xFFFF)) }
# The time of the first move: it is already input (30 px away).
$t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
[Lab054.Win]::PostMessageW($h, $WM_MOUSEMOVE, [IntPtr]::Zero, (& $pos ($c.X + 30) ($c.Y + 20))) | Out-Null
Start-Sleep -Milliseconds 20
[Lab054.Win]::PostMessageW($h, $WM_MOUSEMOVE, [IntPtr]::Zero, (& $pos $c.X $c.Y)) | Out-Null
$t
