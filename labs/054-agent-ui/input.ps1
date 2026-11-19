# Lab 054 helper: the person's mouse moving over the viewer's picture, without touching the real cursor: two
# WM_MOUSEMOVE messages posted to the viewer's window (SDL turns them into motion events, as for a real move).
# Prints the Unix ms of the second one, so take-control.mjs can measure input → agent paused.
#   pwsh -NoProfile -File input.ps1            (the first GpuVMViewer window found)
Add-Type -Namespace Lab054 -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
'@
$p = Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { 'no-viewer'; exit 1 }
$h = $p.MainWindowHandle
$WM_MOUSEMOVE = 0x0200
$pos = { param($x, $y) [IntPtr](($y -shl 16) -bor $x) }
[Lab054.Win]::PostMessageW($h, $WM_MOUSEMOVE, [IntPtr]::Zero, (& $pos 400 300)) | Out-Null
Start-Sleep -Milliseconds 20
$t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
[Lab054.Win]::PostMessageW($h, $WM_MOUSEMOVE, [IntPtr]::Zero, (& $pos 430 320)) | Out-Null
$t
