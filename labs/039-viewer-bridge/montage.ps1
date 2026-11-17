# Lab 039 helper: one contact sheet from filmed frames (screen.ps1 film), with each frame's time on it.
#   montage.ps1 -Dir frames -Out sheet.jpg [-From 0] [-Count 32] [-Step 1] [-Cols 4] [-Width 480]
param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Out, [int]$From = 0, [int]$Count = 32,
    [int]$Step = 1, [int]$Cols = 4, [int]$Width = 480)
Add-Type -AssemblyName System.Drawing
$all = @(Get-ChildItem $Dir -Filter *.jpg | Sort-Object Name)
$files = @(for ($i = $From; $i -lt [Math]::Min($all.Count, $From + $Count * $Step); $i += $Step) { $all[$i] })
$first = [System.Drawing.Image]::FromFile($files[0].FullName)
$th = [int]($first.Height * $Width / $first.Width); $first.Dispose()
$rows = [Math]::Ceiling($files.Count / $Cols)
$bmp = [System.Drawing.Bitmap]::new($Cols * $Width, $rows * ($th + 14))
$g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear([System.Drawing.Color]::White)
$font = [System.Drawing.Font]::new('Arial', 9)
for ($i = 0; $i -lt $files.Count; $i++) {
    $img = [System.Drawing.Image]::FromFile($files[$i].FullName)
    $x = ($i % $Cols) * $Width; $y = [Math]::Floor($i / $Cols) * ($th + 14)
    $g.DrawImage($img, $x, $y + 14, $Width, $th)
    $g.DrawString($files[$i].BaseName, $font, [System.Drawing.Brushes]::Black, $x + 2, $y)
    $img.Dispose()
}
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Jpeg); $g.Dispose(); $bmp.Dispose()
"$($files.Count) frames"
