# Saves what this PC's screen shows (all monitors) as a PNG: the person's view of the app while an agent works.
#   pwsh -NoProfile -File labs/053-mcp/host-shot.ps1 [-Out path]
param([string]$Out = (Join-Path $PSScriptRoot "out\host-$(Get-Date -Format 'yyyyMMdd-HHmmss').png"))
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Name Dpi -Namespace Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][Win.Dpi]::SetProcessDPIAware()
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = [System.Drawing.Bitmap]::new($b.Width, $b.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
try {
    $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
    New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
    $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
    $Out
}
finally { $g.Dispose(); $bmp.Dispose() }
