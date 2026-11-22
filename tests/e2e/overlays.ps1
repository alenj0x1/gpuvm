<#
.SYNOPSIS
End-to-end check of what the person SEES over a machine's picture, on the installed GpuVM: run before every release.

.DESCRIPTION
Drives the real app the way an agent and a person do, and checks the screen itself (UI Automation for the text, the
screen's pixels for whether it is really drawn), not the code:

  1. An agent (an MCP session of gpuvm.exe --mcp) creates a disposable machine and opens its viewer: the agent is told
     the person sees it, and the picture is really in front (the window under the screen's center is the viewer's).
  2. The agent clicks with an intent: the status notch shows its line ("<client> · <intent>"), drawn (dark pixels where
     the notch is), and the live overlay's cursor label is on screen.
  3. The person clicks the picture: the agent is paused and the notch says the person took control, drawn.
  4. Ctrl+Alt+Shift+R: the notch shows "Recording", drawn; again: it goes.
  5. The side panel opens and closes (Ctrl+Alt+Shift+G) while the screen is filmed at ~25 fps: no white patch appears
     for a moment anywhere (the "white panel" of 2026-11-21).
  6. Ctrl+Alt+Shift+A gives the machine back: the control notice goes.
  7. The machine is destroyed.

Why: on 2026-11-21 the notch had its text but Windows showed it as an empty white bar, so "Recording" and "You took
control" were invisible, and a white strip flashed when the panel closed. Every unit test passed. Only a check of the
pixels on screen catches that.

Needs: GpuVM installed and running, the agent-tpl template, ~4 GB of free memory, nobody using the mouse or the
keyboard for the ~3 minutes it takes (it clicks and types into the viewer). Not administrator.

.EXAMPLE
pwsh -File tests\e2e\overlays.ps1
#>
param(
    [string]$Template = 'agent-tpl',
    [string]$Exe = 'C:\Program Files\GpuVM\gpuvm.exe',
    [string]$Out = (Join-Path ([IO.Path]::GetTempPath()) "gpuvm-e2e-$(Get-Date -Format yyyyMMdd-HHmmss)"),
    [switch]$KeepMachine
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Out | Out-Null
Add-Type -AssemblyName System.Drawing, System.Windows.Forms, UIAutomationClient, UIAutomationTypes
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class E2E {
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint f, IntPtr e);
  [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  public struct RECT { public int L, T, R, B; }
  public struct POINT { public int X, Y; }
  public static void Click(int x, int y) { SetCursorPos(x, y); System.Threading.Thread.Sleep(60); mouse_event(2,0,0,0,IntPtr.Zero); System.Threading.Thread.Sleep(40); mouse_event(4,0,0,0,IntPtr.Zero); }
  [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
  // With each key's scan code: the viewer (SDL) reads scan codes, and without them it took the keys for other shortcuts.
  static void Key(byte vk, bool up) { keybd_event(vk, (byte)MapVirtualKey(vk, 0), up ? 2u : 0u, IntPtr.Zero); System.Threading.Thread.Sleep(30); }
  public static void Combo(byte key) { byte[] mods = {0x11, 0x12, 0x10}; foreach (var m in mods) Key(m, false); Key(key, false); Key(key, true); for (int i = 2; i >= 0; i--) Key(mods[i], true); }
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  // The visible top-level windows of a process (the notch is owned by the viewer, so UI Automation's list of the
  // desktop's children doesn't show it).
  [DllImport("user32.dll")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
  // GpuVM's small windows over the picture (not its main window) that have a caption: Windows draws it as a white
  // "GpuVM" title bar.
  public static int Captioned(uint pid) { int n = 0; foreach (var h in WindowsOf(pid)) { var r = Rect(h); long style = (long)GetWindowLongPtr(h, -16); if (r[2] < 900 && r[2] > 20 && (style & 0xC00000) == 0xC00000) n++; } return n; }
  [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
  [DllImport("gdi32.dll")] static extern uint GetPixel(IntPtr dc, int x, int y);
  // A pale grey pixel on screen (what Windows 10 shows where a transparent window should be see-through).
  public static bool Pale(int x, int y) { IntPtr dc = GetDC(IntPtr.Zero); uint p = GetPixel(dc, x, y); ReleaseDC(IntPtr.Zero, dc); int r = (int)(p & 0xFF), g = (int)((p >> 8) & 0xFF), b = (int)((p >> 16) & 0xFF); int mx = Math.Max(r, Math.Max(g, b)), mn = Math.Min(r, Math.Min(g, b)); return r + g + b > 560 && mx - mn < 18; }
  public static IntPtr[] WindowsOf(uint pid) { var list = new System.Collections.Generic.List<IntPtr>(); EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) list.Add(h); return true; }, IntPtr.Zero); return list.ToArray(); }
  public static uint ProcessAt(int x, int y) { var p = new POINT { X = x, Y = y }; IntPtr h = GetAncestor(WindowFromPoint(p), 2); uint pid; GetWindowThreadProcessId(h, out pid); return pid; }
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
  public static string Describe(IntPtr h) { uint pid; GetWindowThreadProcessId(h, out pid); var c = new System.Text.StringBuilder(128); GetClassName(h, c, 128); string name = "?"; try { name = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch {} return name + "/" + c; }
  public static string At(int x, int y) { var p = new POINT { X = x, Y = y }; return Describe(WindowFromPoint(p)); }
  public static string Foreground() { return Describe(GetForegroundWindow()); }
  public static int[] Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return new[] { r.L, r.T, r.R - r.L, r.B - r.T }; }
  // Pixels as BGRA bytes (Bitmap.LockBits in PowerShell). Share of the pixels that are dark (the notch is drawn dark in
  // both themes) and that are light.
  public static double[] Tones(byte[] p) { int dark = 0, light = 0, n = 0; for (int i = 0; i + 3 < p.Length; i += 8) { int s = p[i] + p[i+1] + p[i+2]; if (s < 200) dark++; if (s > 600) light++; n++; } return new[] { (double)dark / n, (double)light / n }; }
  // Near-white pixels in a frame that were not white in the one before nor stay white two frames later: a flash.
  public static int Flash(byte[] before, byte[] now, byte[] after) { int n = 0; for (int i = 0; i + 3 < now.Length; i += 8) { if (W(now, i) && !W(before, i) && !W(after, i)) n++; } return n; }
  static bool W(byte[] p, int i) { return p[i] + p[i+1] + p[i+2] > 735; }
}
'@

function Grab([int]$X, [int]$Y, [int]$W, [int]$H) {
    $b = [Drawing.Bitmap]::new($W, $H)
    $g = [Drawing.Graphics]::FromImage($b); $g.CopyFromScreen($X, $Y, 0, 0, [Drawing.Size]::new($W, $H)); $g.Dispose()
    $b
}
function Bytes([Drawing.Bitmap]$B) {
    $d = $B.LockBits([Drawing.Rectangle]::new(0, 0, $B.Width, $B.Height), 'ReadOnly', 'Format32bppArgb')
    $bytes = [byte[]]::new($d.Stride * $B.Height); [Runtime.InteropServices.Marshal]::Copy($d.Scan0, $bytes, 0, $bytes.Length)
    $B.UnlockBits($d); , $bytes
}

$results = [System.Collections.Generic.List[object]]::new()
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ Check = $Name; Ok = $Ok; Detail = $Detail })
    Write-Host ("{0}  {1}{2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $(if ($Detail) { " - $Detail" } else { '' }))
}
function Shot([string]$Name) {
    $b = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = Grab $b.X $b.Y $b.Width $b.Height; $bmp.Save((Join-Path $Out "$Name.png")); $bmp.Dispose()
}

# ---------- an agent: an MCP session of GpuVM's own server
$psi = [Diagnostics.ProcessStartInfo]::new($Exe, '--mcp')
$psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
$psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
$mcp = [Diagnostics.Process]::Start($psi)
$script:id = 0
function Rpc([string]$Method, $Params, [switch]$Notify) {
    $msg = [ordered]@{ jsonrpc = '2.0'; method = $Method }
    if ($null -ne $Params) { $msg.params = $Params }
    if (-not $Notify) { $script:id++; $msg.id = $script:id }
    $mcp.StandardInput.WriteLine(($msg | ConvertTo-Json -Depth 10 -Compress)); $mcp.StandardInput.Flush()
    if ($Notify) { return }
    while ($true) {
        $line = $mcp.StandardOutput.ReadLine()
        if ($null -eq $line) { throw 'The MCP server closed.' }
        $r = $line | ConvertFrom-Json
        if ($r.id -eq $script:id) { return $r }
    }
}
# Sends a tool call and returns at once (the notch is looked at while it runs); Finish reads its answer.
function Start-Tool([string]$Name, [hashtable]$Arguments) {
    $script:id++
    $msg = [ordered]@{ jsonrpc = '2.0'; method = 'tools/call'; params = @{ name = $Name; arguments = $Arguments }; id = $script:id }
    $mcp.StandardInput.WriteLine(($msg | ConvertTo-Json -Depth 10 -Compress)); $mcp.StandardInput.Flush()
    $script:id
}
function Finish-Tool([int]$Id) {
    while ($true) {
        $line = $mcp.StandardOutput.ReadLine()
        if ($null -eq $line) { throw 'The MCP server closed.' }
        $r = $line | ConvertFrom-Json
        if ($r.id -eq $Id) { return (@($r.result.content) | Where-Object type -eq 'text' | ForEach-Object text) -join ' ' }
    }
}
function Tool([string]$Name, [hashtable]$Arguments) {
    $r = Rpc 'tools/call' @{ name = $Name; arguments = $Arguments }
    (@($r.result.content) | Where-Object type -eq 'text' | ForEach-Object text) -join ' '
}
$null = Rpc 'initialize' @{ protocolVersion = '2025-06-18'; capabilities = @{}; clientInfo = @{ name = 'e2e'; version = '1' } }
Rpc 'notifications/initialized' $null -Notify

# ---------- what is on screen: the app's windows and the notch's text through UI Automation
$app = (Get-Process gpuvm | Where-Object MainWindowTitle -eq 'GpuVM' | Select-Object -First 1)
if (-not $app) { throw 'GpuVM is not running.' }
function Notch {
    # The notch: a window of GpuVM's process whose page holds the status bar ("sn"). Its rectangle and text.
    foreach ($h in [E2E]::WindowsOf([uint32]$app.Id)) {
        if ([E2E]::Rect($h)[2] -ge 900) { continue }
        $w = try { [Windows.Automation.AutomationElement]::FromHandle($h) } catch { continue }
        $bar = $w.FindFirst([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::StatusBar))
        if (-not $bar -or $bar.Current.ClassName -notmatch '^sn\b') { continue }
        $texts = $bar.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name } | Where-Object { $_ }
        $r = $bar.Current.BoundingRectangle
        return [pscustomobject]@{ Text = ($texts -join ' '); X = [int]$r.X; Y = [int]$r.Y; W = [int]$r.Width; H = [int]$r.Height }
    }
    $null
}
function Wait-Notch([string]$Pattern, [int]$Seconds = 15) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do { $n = Notch; if ($n -and $n.Text -match $Pattern) { return $n }; Start-Sleep -Milliseconds 300 } while ((Get-Date) -lt $deadline)
    Notch
}
# Drawn means: the notch's rectangle on screen is mostly the notch's dark pill, not a white bar or the picture.
function Check-Drawn([string]$Name, $n) {
    if (-not $n -or $n.W -lt 20 -or $n.H -lt 10) { Check "$Name is drawn" $false 'no notch on screen'; return }
    Start-Sleep -Milliseconds 400
    $bmp = Grab ($n.X + 4) ($n.Y + 4) ($n.W - 8) ($n.H - 8)
    $t = [E2E]::Tones((Bytes $bmp)); $bmp.Save((Join-Path $Out "$($Name -replace '\W','-').png")); $bmp.Dispose()
    Check "$Name is drawn" ($t[0] -ge 0.45 -and $t[1] -le 0.25) ("dark {0:P0}, light {1:P0} of its rectangle" -f $t[0], $t[1])
    # Its rounded corners show the picture, not a pale box (the desktop behind is the machine's blue wallpaper).
    $pale = @(@($n.X + 1, $n.Y + 1), @($n.X + $n.W - 2, $n.Y + 1), @($n.X + 1, $n.Y + $n.H - 2), @($n.X + $n.W - 2, $n.Y + $n.H - 2) | Where-Object { [E2E]::Pale($_[0], $_[1]) }).Count
    Check "$Name has no pale box around it" ($pale -eq 0) "$pale of 4 corners pale"
}

$machine = $null
try {
    # 1. A disposable machine, opened for the person to watch.
    $created = Tool 'create_disposable' @{ template = $Template; task = 'End-to-end check' }
    $machine = [regex]::Match($created, "$Template-[0-9a-f]{6}").Value
    Check 'agent creates a disposable machine' ([bool]$machine) $created
    if (-not $machine) { throw 'No machine to check.' }
    $opened = Tool 'open_viewer' @{ machine = $machine; waitSeconds = 180 }
    Check 'agent is told the person sees the picture' ($opened -match 'now sees|already shows') $opened
    Start-Sleep -Seconds 2
    $screen = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $cx = [int]($screen.Width / 2); $cy = [int]($screen.Height / 2)
    $front = (Get-Process -Id ([E2E]::ProcessAt($cx, $cy))).ProcessName
    Check 'the picture is in front of the other windows' ($front -eq 'GpuVMViewer') "window at the screen's center: $front"
    Shot '1-opened'

    # 2. The agent acts: its line in the notch and its cursor over the picture.
    $null = Tool 'screenshot' @{ machine = $machine; maxWidth = 640 }
    # A click that waits 8 s after acting: its step runs that long, with its intent in the notch.
    $pending = Start-Tool 'click' @{ machine = $machine; x = 320; y = 200; intent = 'Checking the notch'; delayMs = 8000 }
    $n = Wait-Notch 'Checking the notch' 7
    Check 'notch shows the agent''s intent' ($n -and $n.Text -match 'Checking the notch') "text: $($n.Text)"
    Check-Drawn 'agent notch' $n
    Shot '2-agent'
    $null = Finish-Tool $pending

    # 3. The person takes control with a click on the picture.
    $under = [E2E]::At($cx, [int]($screen.Height * 0.4))
    [E2E]::Click($cx, [int]($screen.Height * 0.4))
    Start-Sleep -Milliseconds 300
    Write-Host "     clicked on $under; in front now: $([E2E]::Foreground())"
    $n = Wait-Notch 'took control|tomaste el control|You have control|Tienes el control'
    Check 'notch says the person took control' ($n -and $n.Text -match 'took control|tomaste el control|have control|Tienes el control') "text: $($n.Text)"
    Check-Drawn 'control notch' $n
    $listed = Tool 'list_machines' @{}
    Check 'the agent is paused' ($listed -match "$machine[^\n]*paused") $listed
    Shot '3-control'

    # 4. Recording on and off.
    [E2E]::Combo([byte][char]'R')
    $n = Wait-Notch 'Recording|Grabando'
    Check 'notch shows Recording' ($n -and $n.Text -match 'Recording|Grabando') "text: $($n.Text)"
    Check-Drawn 'recording notch' $n
    Shot '4-recording'
    [E2E]::Combo([byte][char]'R')
    Start-Sleep -Seconds 2

    # 5. The side panel opens and closes, filmed: no white patch for a moment.
    [E2E]::Combo([byte][char]'G')
    Start-Sleep -Seconds 2
    Shot '5-panel-open'
    $frames = [System.Collections.Generic.List[System.Drawing.Bitmap]]::new()
    $half = { $f = Grab $screen.X $screen.Y $screen.Width $screen.Height; $s = [Drawing.Bitmap]::new($f, [int]($screen.Width / 2), [int]($screen.Height / 2)); $f.Dispose(); $s }
    $frames.Add((& $half))
    [E2E]::Combo([byte][char]'G')
    $sw = [Diagnostics.Stopwatch]::StartNew(); $captions = 0
    while ($sw.ElapsedMilliseconds -lt 2500) { $frames.Add((& $half)); $captions = [Math]::Max($captions, [E2E]::Captioned([uint32]$app.Id)) }
    Check 'no GpuVM title bar shows while the panel closes' ($captions -eq 0) "$captions captioned window(s) seen"
    $worst = 0; $at = -1
    $raw = @($frames | ForEach-Object { , (Bytes $_) })
    for ($i = 1; $i -lt $frames.Count - 2; $i++) {
        $f = [E2E]::Flash($raw[$i - 1], $raw[$i], $raw[$i + 2])
        if ($f -gt $worst) { $worst = $f; $at = $i }
    }
    if ($at -ge 0) { $frames[$at].Save((Join-Path $Out '5-panel-close-worst.png')) }
    Check 'closing the panel flashes nothing white' ($worst -lt 150) "$($frames.Count) frames, largest short-lived white patch $worst px (frame $at)"
    $frames | ForEach-Object { $_.Dispose() }

    # 6. Back to the agent.
    [E2E]::Click($cx, [int]($screen.Height * 0.4))
    [E2E]::Combo([byte][char]'A')
    Start-Sleep -Seconds 3
    $n = Notch
    Check 'Ctrl+Alt+Shift+A gives the machine back' (-not ($n -and $n.Text -match 'took control|tomaste el control|have control|Tienes el control')) "notch: $($n.Text)"
}
catch {
    Check 'run' $false $_.Exception.Message
}
finally {
    if ($machine -and -not $KeepMachine) { $null = Tool 'destroy' @{ machine = $machine; force = $true } }
    try { $mcp.StandardInput.Close(); $null = $mcp.WaitForExit(5000) } catch { }
}

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host ''
Write-Host "$($results.Count - $failed.Count) of $($results.Count) passed. Screenshots: $Out"
# A pass on a clean checkout is recorded for scripts/release.py, which refuses to release a commit without one.
if (-not $failed.Count) {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $commit = (git -C $repo rev-parse HEAD).Trim()
    $dirty = [bool](git -C $repo status --porcelain)
    if ($dirty) { Write-Host 'Not recorded for the release: the checkout has uncommitted changes.' }
    else {
        [ordered]@{ commit = $commit; exe = (Get-FileHash -LiteralPath $Exe).Hash; at = (Get-Date).ToUniversalTime().ToString('o'); checks = $results.Count } |
            ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $PSScriptRoot '.last-pass.json')
        Write-Host "Recorded for the release: commit $commit."
    }
}
exit [int]($failed.Count -gt 0)
