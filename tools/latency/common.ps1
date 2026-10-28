# Shared helpers for the latency tools: VM access through the GpuVM module, the variants under test,
# starting and stopping Moonlight, and screen capture.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force -DisableNameChecking

function Get-LatencyVM {
    param([Parameter(Mandatory)][string]$Name)
    $module = Get-Module GpuVM
    $state = & $module { param($n) Get-GpuVMState -Name $n } $Name
    $guest = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state
    if (-not $guest) { throw "Save the Windows password of '$Name' in GpuVM first." }
    [pscustomobject]@{
        Name    = $Name
        Module  = $module
        Guest   = $guest
        Address = & $module { param($n) Get-GpuVMAddress -Name $n } $Name
        Sunshine = & $module { param($s) Get-SunshineCredential -State $s } $state
    }
}

# baseline = what GpuVM uses today (60 FPS, Moonlight's default V-Sync on); candidates change one thing each.
function Get-LatencyVariants {
    @(
        [pscustomobject]@{ Name = 'baseline-60-vsync'; Fps = 60; VSync = $true }
        [pscustomobject]@{ Name = 'candidate-60-novsync'; Fps = 60; VSync = $false }
        [pscustomobject]@{ Name = 'candidate-120-novsync'; Fps = 120; VSync = $false }
        [pscustomobject]@{ Name = 'candidate-144-novsync'; Fps = 144; VSync = $false }
    )
}

function Start-LatencyStream {
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)]$Variant,
        [string]$App = 'Desktop',
        [switch]$Overlay
    )
    Get-Process Moonlight -ErrorAction SilentlyContinue | Stop-Process -Force
    $result = & $VM.Module { param($n, $c, $f) Set-GuestDisplayResolution -Name $n -Credential $c -Resolution '1920x1080' -Fps $f } $VM.Name $VM.Guest $Variant.Fps
    $applied = if ($result.PSObject.Properties['applied']) { $result.applied } else { "not applied: $($result.error)" }
    Start-Sleep -Seconds 2
    $moonlight = Join-Path $env:ProgramFiles 'Moonlight Game Streaming\Moonlight.exe'
    $arguments = @('stream', $VM.Address, $App, '--resolution', '1920x1080', '--fps', "$($Variant.Fps)", '--display-mode', 'borderless', '--no-frame-pacing')
    $arguments += if ($Variant.VSync) { '--vsync' } else { '--no-vsync' }
    $arguments += if ($Overlay) { '--performance-overlay' } else { '--no-performance-overlay' }
    $process = Start-Process $moonlight -ArgumentList $arguments -PassThru
    [pscustomobject]@{ Process = $process; Display = $applied }
}

# Killing Moonlight leaves the session open in Sunshine; changing the display's refresh rate under an open session
# leaves the next stream black, so the session is closed in Sunshine too before the next variant.
function Stop-LatencyStream {
    param([Parameter(Mandatory)]$Session, $VM)
    Stop-Process -Id $Session.Process.Id -Force -ErrorAction SilentlyContinue
    if ($VM) {
        try { & $VM.Module { param($a, $c) Invoke-SunshineApi -Address $a -Credential $c -Method POST -Path '/api/apps/close' } $VM.Address $VM.Sunshine | Out-Null }
        catch { Write-Warning "Sunshine did not close the session: $($_.Exception.Message)" }
    }
    Start-Sleep -Seconds 4
}

function Save-ScreenRegion {
    param([Parameter(Mandatory)][string]$Path, [int]$X = 0, [int]$Y = 0, [int]$Width, [int]$Height)
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    if (-not $Width) { $Width = $bounds.Width }
    if (-not $Height) { $Height = $bounds.Height }
    $bmp = New-Object System.Drawing.Bitmap $Width, $Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.Left + $X, $bounds.Top + $Y, 0, 0, $bmp.Size)
    $g.Dispose()
    $bmp.Save($Path)
    $bmp.Dispose()
}

# Screen pixel reads and key presses used by the end-to-end meter.
if (-not ('GpuVMLatency' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class GpuVMLatency {
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("gdi32.dll")] static extern uint GetPixel(IntPtr dc, int x, int y);

    // Brightness 0-255 of one screen pixel.
    public static int Brightness(int x, int y) {
        IntPtr dc = GetDC(IntPtr.Zero);
        uint c = GetPixel(dc, x, y);
        ReleaseDC(IntPtr.Zero, dc);
        return (int)(((c & 0xFF) + ((c >> 8) & 0xFF) + ((c >> 16) & 0xFF)) / 3);
    }

    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);

    public static void Key(byte vk) {
        keybd_event(vk, 0, 0, UIntPtr.Zero);
        keybd_event(vk, 0, 2, UIntPtr.Zero);
    }

    // Presses Scroll Lock (sent to the VM by Moonlight) and returns the milliseconds until the pixel crosses
    // mid-gray in the expected direction; -1 on timeout.
    public static double Measure(int px, int py, bool expectLit, int timeoutMs) {
        var watch = Stopwatch.StartNew();
        Key(0x91);
        while (watch.ElapsedMilliseconds < timeoutMs) {
            bool lit = Brightness(px, py) > 128;
            if (lit == expectLit) return watch.Elapsed.TotalMilliseconds;
        }
        return -1;
    }
}
'@
}

# Waits until Moonlight shows the stream (its log says "Video stream is"), instead of a fixed warmup: at 120/144 FPS
# the first frame takes up to ~30 s, at 60 FPS a few seconds. Returns the seconds it took, or -1 on timeout.
function Wait-LatencyStreamVisible {
    param([Parameter(Mandatory)][datetime]$Since, [int]$TimeoutSec = 90)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $log = Get-ChildItem $env:TEMP -Filter 'Moonlight*.log' -ErrorAction SilentlyContinue |
            Where-Object LastWriteTime -ge $Since | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($log -and (Select-String -LiteralPath $log.FullName -Pattern 'Video stream is' -Quiet)) { return [math]::Round($watch.Elapsed.TotalSeconds, 1) }
        Start-Sleep -Milliseconds 500
    }
    -1
}
