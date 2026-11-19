# Cuts a region out of a screenshot (to show only the app, not the rest of the person's desktop).
#   pwsh -NoProfile -File labs/053-mcp/crop.ps1 -In a.png -Out b.png -X 1920 -Y 0 -Width 1920 -Height 1080
param([Parameter(Mandatory)][string]$In, [Parameter(Mandatory)][string]$Out, [int]$X, [int]$Y, [int]$Width, [int]$Height)
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Bitmap]::FromFile((Resolve-Path $In))
try {
    $rect = [System.Drawing.Rectangle]::new($X, $Y, [math]::Min($Width, $src.Width - $X), [math]::Min($Height, $src.Height - $Y))
    $part = $src.Clone($rect, $src.PixelFormat)
    try { $part.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png); $Out } finally { $part.Dispose() }
}
finally { $src.Dispose() }
