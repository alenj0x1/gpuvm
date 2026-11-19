# Lab 054 helper: a screenshot of one GpuVM window's area only (the app, or the viewer), to check the installed build.
#   pwsh -NoProfile -File window-shot.ps1 -Process gpuvm -Out shot.png
param([string]$Process = 'gpuvm', [Parameter(Mandatory)][string]$Out)
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace Lab054 -Name Rect -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
[Lab054.Rect]::SetProcessDPIAware() | Out-Null
$p = Get-Process $Process -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
$r = New-Object Lab054.Rect+R
[Lab054.Rect]::GetWindowRect($p.MainWindowHandle, [ref]$r) | Out-Null
$w = $r.Rt - $r.L; $h = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
"$w x $h"
