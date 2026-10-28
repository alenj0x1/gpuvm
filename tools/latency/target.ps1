# Latency target that runs inside the VM, in the user's session (Windows PowerShell 5.1).
# - A bar moves across the bottom all the time, so Sunshine streams real frames instead of a still desktop.
# - The center square switches between black and white on every Scroll Lock press (read globally, so the
#   focus doesn't matter) or click; the host measures how long that change takes to show up in Moonlight
#   (tools/latency/measure.ps1).
# It closes itself after -Minutes so it never stays behind.
param([int]$Minutes = 20)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition @'
using System.Windows.Forms;
public class GpuVMCanvas : Panel {
    public GpuVMCanvas() { DoubleBuffered = true; SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.Opaque, true); }
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    // Scroll Lock is read globally, so it works even when another window (Start menu, a dialog) has the focus.
    public static bool ScrollLockDown() { return (GetAsyncKeyState(0x91) & 0x8000) != 0; }
}
'@ -ReferencedAssemblies System.Windows.Forms

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.WindowState = 'Maximized'
$form.TopMost = $true
$form.BackColor = [System.Drawing.Color]::Black
$form.KeyPreview = $true

$canvas = New-Object GpuVMCanvas
$canvas.Dock = 'Fill'
$form.Controls.Add($canvas)

$script:lit = $false
$script:frames = 0
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$toggle = { $script:lit = -not $script:lit; $canvas.Invalidate() }
$canvas.Add_MouseDown($toggle)
$form.Add_KeyDown($toggle)

$canvas.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $w = $sender.ClientSize.Width; $h = $sender.ClientSize.Height
    $g.Clear([System.Drawing.Color]::Black)
    $side = [int]($h * 0.4)
    $square = New-Object System.Drawing.Rectangle ([int](($w - $side) / 2)), ([int](($h - $side) / 2)), $side, $side
    $fill = if ($script:lit) { [System.Drawing.Brushes]::White } else { [System.Drawing.Brushes]::Black }
    $g.FillRectangle($fill, $square)
    $g.DrawRectangle([System.Drawing.Pens]::DimGray, $square)
    # Moving bar: one full sweep per second.
    $x = [int](($clock.Elapsed.TotalSeconds % 1) * ($w - 120))
    $g.FillRectangle([System.Drawing.Brushes]::OrangeRed, $x, $h - 80, 120, 60)
})

$form.Show()
$form.Activate()
$deadline = (Get-Date).AddMinutes($Minutes)
$wasDown = $false
while ($form.Visible -and (Get-Date) -lt $deadline) {
    $down = [GpuVMCanvas]::ScrollLockDown()
    if ($down -and -not $wasDown) { $script:lit = -not $script:lit }
    $wasDown = $down
    $canvas.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}
$form.Close()
