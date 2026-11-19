# Lab 054 helper: the bottom-right corner of the primary screen (where Windows shows notifications).
#   pwsh -NoProfile -File screen-shot.ps1 -Out toast.png [-Width 520] [-Height 420]
param([Parameter(Mandatory)][string]$Out, [int]$Width = 520, [int]$Height = 420)
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -Namespace Lab054 -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[Lab054.Dpi]::SetProcessDPIAware() | Out-Null
$s = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap $Width, $Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($s.Right - $Width, $s.Bottom - $Height, 0, 0, $bmp.Size)
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
"$Width x $Height"
