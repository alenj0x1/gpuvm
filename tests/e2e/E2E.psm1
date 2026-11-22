$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms, UIAutomationClient, UIAutomationTypes

Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text; using System.Collections.Generic;
public static class E2E {
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint f, IntPtr e);
  [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
  [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
  [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
  [DllImport("gdi32.dll")] static extern uint GetPixel(IntPtr dc, int x, int y);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  public struct RECT { public int L, T, R, B; }
  public struct POINT { public int X, Y; }

  // A person's click: the pointer arrives first (moves over the window), then presses.
  public static void Click(int x, int y) { SetCursorPos(x - 40, y - 30); System.Threading.Thread.Sleep(80); for (int i = 1; i <= 8; i++) { SetCursorPos(x - 40 + 5 * i, y - 30 + (30 * i) / 8); System.Threading.Thread.Sleep(15); } System.Threading.Thread.Sleep(150); mouse_event(2,0,0,0,IntPtr.Zero); System.Threading.Thread.Sleep(40); mouse_event(4,0,0,0,IntPtr.Zero); }
  public static void Move(int x, int y) { SetCursorPos(x, y); }
  // The viewer (SDL) reads scan codes.
  static void Key(byte vk, bool up) { keybd_event(vk, (byte)MapVirtualKey(vk, 0), up ? 2u : 0u, IntPtr.Zero); System.Threading.Thread.Sleep(30); }
  public static void Combo(byte key) { byte[] mods = {0x11, 0x12, 0x10}; foreach (var m in mods) Key(m, false); Key(key, false); Key(key, true); for (int i = 2; i >= 0; i--) Key(mods[i], true); }

  public static string Describe(IntPtr h) { uint pid; GetWindowThreadProcessId(h, out pid); var c = new StringBuilder(128); GetClassName(h, c, 128); string name = "?"; try { name = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch {} return name + "/" + c; }
  public static string ProcessNameAt(int x, int y) { var p = new POINT { X = x, Y = y }; IntPtr h = GetAncestor(WindowFromPoint(p), 2); uint pid; GetWindowThreadProcessId(h, out pid); try { return System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { return "?"; } }
  public static string At(int x, int y) { var p = new POINT { X = x, Y = y }; return Describe(WindowFromPoint(p)); }
  public static string Foreground() { return Describe(GetForegroundWindow()); }
  public static int[] Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return new[] { r.L, r.T, r.R - r.L, r.B - r.T }; }
  // Owned windows (the notch, the docks) don't show in UI Automation's list of the desktop's children.
  public static IntPtr[] WindowsOf(uint pid) { var list = new List<IntPtr>(); EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) list.Add(h); return true; }, IntPtr.Zero); return list.ToArray(); }
  // Windows draws a caption on GpuVM's small windows as a white "GpuVM" title bar.
  public static int Captioned(uint pid) { int n = 0; foreach (var h in WindowsOf(pid)) { var r = Rect(h); long style = (long)GetWindowLongPtr(h, -16); if (r[2] < 900 && r[2] > 20 && (style & 0xC00000) == 0xC00000) n++; } return n; }
  public static int[] Pixel(int x, int y) { IntPtr dc = GetDC(IntPtr.Zero); uint p = GetPixel(dc, x, y); ReleaseDC(IntPtr.Zero, dc); return new[] { (int)(p & 0xFF), (int)((p >> 8) & 0xFF), (int)((p >> 16) & 0xFF) }; }
  // What Windows 10 shows where a transparent window should be see-through.
  public static bool Pale(int x, int y) { var c = Pixel(x, y); int mx = Math.Max(c[0], Math.Max(c[1], c[2])), mn = Math.Min(c[0], Math.Min(c[1], c[2])); return c[0] + c[1] + c[2] > 560 && mx - mn < 18; }
  // BGRA bytes: share of dark and of light pixels.
  public static double[] Tones(byte[] p) { int dark = 0, light = 0, n = 0; for (int i = 0; i + 3 < p.Length; i += 8) { int s = p[i] + p[i+1] + p[i+2]; if (s < 200) dark++; if (s > 600) light++; n++; } return new[] { (double)dark / n, (double)light / n }; }
  // Short-lived patches: 4x4 blocks (of a BGRA frame `stride` bytes wide) where nearly every pixel is pale (or black)
  // now but wasn't just before nor two frames later. A bar or a box fills blocks; thin animated lines don't.
  public static int Flash(byte[] before, byte[] now, byte[] after, int stride) { return Blocks(before, now, after, stride, false); }
  public static int FlashBlack(byte[] before, byte[] now, byte[] after, int stride) { return Blocks(before, now, after, stride, true); }
  static int Blocks(byte[] b, byte[] n, byte[] a, int stride, bool black) {
    int w = stride / 4, h = n.Length / stride, count = 0;
    for (int by = 0; by + 4 <= h; by += 4) for (int bx = 0; bx + 4 <= w; bx += 4) {
      int hit = 0;
      for (int y = by; y < by + 4; y++) for (int x = bx; x < bx + 4; x++) {
        int i = y * stride + x * 4;
        bool now = black ? K(n, i) : W(n, i);
        if (now && !(black ? K(b, i) : W(b, i)) && !(black ? K(a, i) : W(a, i))) hit++;
      }
      if (hit >= 14) count++;
    }
    return count;
  }
  static bool K(byte[] p, int i) { return p[i] + p[i+1] + p[i+2] < 45; }
  // White, or the pale grey of a semi-transparent white over the picture (low chroma, bright).
  static bool W(byte[] p, int i) { int b = p[i], g = p[i+1], r = p[i+2]; int mx = Math.Max(r, Math.Max(g, b)), mn = Math.Min(r, Math.Min(g, b)); return r + g + b > 600 && mx - mn < 24; }
  // Near-black pixels in a box: Windows' arrow cursor has a black edge; the agent's cursor (green, white edge) and the
  // blue wallpaper have none.
  public static int Black(int x, int y, int w, int h) { IntPtr dc = GetDC(IntPtr.Zero); int n = 0; for (int j = 0; j < h; j++) for (int i = 0; i < w; i++) { uint p = GetPixel(dc, x + i, y + j); if ((p & 0xFF) + ((p >> 8) & 0xFF) + ((p >> 16) & 0xFF) < 90) n++; } ReleaseDC(IntPtr.Zero, dc); return n; }
  public static int White(int x, int y, int w, int h) { IntPtr dc = GetDC(IntPtr.Zero); int n = 0; for (int j = 0; j < h; j++) for (int i = 0; i < w; i++) { uint p = GetPixel(dc, x + i, y + j); if ((p & 0xFF) > 245 && ((p >> 8) & 0xFF) > 245 && ((p >> 16) & 0xFF) > 245) n++; } ReleaseDC(IntPtr.Zero, dc); return n; }
}
'@

$script:Results = [System.Collections.Generic.List[object]]::new()
$script:Out = $null

function Start-E2ERun([string]$Out) {
    $script:Out = $Out
    New-Item -ItemType Directory -Force $Out | Out-Null
    $script:Results.Clear()
}

function Get-E2EResults { , $script:Results }

function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $script:Results.Add([pscustomobject]@{ Check = $Name; Ok = $Ok; Detail = $Detail })
    Write-Host ("{0}  {1}{2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $(if ($Detail) { " - $Detail" } else { '' }))
}

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

function Screen { [Windows.Forms.Screen]::PrimaryScreen.Bounds }

function Shot([string]$Name) {
    $s = Screen
    $bmp = Grab $s.X $s.Y $s.Width $s.Height; $bmp.Save((Join-Path $script:Out "$Name.png")); $bmp.Dispose()
}

function Wait-For([scriptblock]$Condition, [double]$Seconds = 15) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do { $r = & $Condition; if ($r) { return $r }; Start-Sleep -Milliseconds 300 } while ((Get-Date) -lt $deadline)
    & $Condition
}

# ---------- the app and its windows through UI Automation

function Get-App { Get-Process gpuvm -ErrorAction SilentlyContinue | Where-Object MainWindowTitle -eq 'GpuVM' | Select-Object -First 1 }

function Get-AppWindows([switch]$Small) {
    $app = Get-App
    if (-not $app) { return @() }
    foreach ($h in [E2E]::WindowsOf([uint32]$app.Id)) {
        $r = [E2E]::Rect($h)
        if ($r[2] -lt 20 -or $r[3] -lt 10) { continue }
        if ($Small -and $r[2] -ge 900) { continue }
        [pscustomobject]@{ Handle = $h; X = $r[0]; Y = $r[1]; W = $r[2]; H = $r[3] }
    }
}

function Get-Element([IntPtr]$Handle) { try { [Windows.Automation.AutomationElement]::FromHandle($Handle) } catch { $null } }

function Find-Named($Root, [string]$Pattern, $Type = $null) {
    if (-not $Root) { return $null }
    foreach ($e in $Root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)) {
        $c = $e.Current
        if ($c.Name -match $Pattern -and (-not $Type -or $c.ControlType -eq $Type)) { return $e }
    }
    $null
}

function Get-Texts($Root) {
    if (-not $Root) { return '' }
    ($Root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name } | Where-Object { $_ }) -join ' | '
}

function Invoke-Element($Element) {
    if (-not $Element) { return $false }
    $p = $null
    if ($Element.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke(); return $true }
    if ($Element.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { $p.Select(); return $true }
    $r = $Element.Current.BoundingRectangle
    if ($r.Width -gt 0) { [E2E]::Click([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2)); return $true }
    $false
}

# A person's click on an element: the pointer goes to its center, which must belong to the expected process (a
# window over it would take the click), then presses.
function Click-Element($Element, [string]$Process = 'gpuvm') {
    if (-not $Element) { return $false }
    $r = $Element.Current.BoundingRectangle
    if ($r.Width -le 0 -or $r.Height -le 0) { return $false }
    $x = [int]($r.X + $r.Width / 2); $y = [int]($r.Y + $r.Height / 2)
    $at = [E2E]::ProcessNameAt($x, $y)
    if ($at -ne $Process) { Write-Host "     click refused: $at is over '$($Element.Current.Name)'"; return $false }
    [E2E]::Click($x, $y)
    $true
}

function Get-MainElement { $app = Get-App; if ($app) { Get-Element $app.MainWindowHandle } }

function Get-Notch {
    foreach ($w in Get-AppWindows -Small) {
        $root = Get-Element $w.Handle
        if (-not $root) { continue }
        $bar = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::StatusBar))
        if (-not $bar -or $bar.Current.ClassName -notmatch '^sn\b') { continue }
        $r = $bar.Current.BoundingRectangle
        return [pscustomobject]@{ Text = (Get-Texts $bar); X = [int]$r.X; Y = [int]$r.Y; W = [int]$r.Width; H = [int]$r.Height }
    }
    $null
}

function Wait-Notch([string]$Pattern, [double]$Seconds = 15) {
    $n = Wait-For { $x = Get-Notch; if ($x -and $x.Text -match $Pattern) { $x } } $Seconds
    if ($n) { $n } else { Get-Notch }
}

function Check-Drawn([string]$Name, $Notch) {
    if (-not $Notch -or $Notch.W -lt 20 -or $Notch.H -lt 10) { Check "$Name is drawn" $false 'not on screen'; return }
    Start-Sleep -Milliseconds 400
    $bmp = Grab ($Notch.X + 4) ($Notch.Y + 4) ($Notch.W - 8) ($Notch.H - 8)
    $t = [E2E]::Tones((Bytes $bmp)); $bmp.Save((Join-Path $script:Out "$($Name -replace '\W','-').png")); $bmp.Dispose()
    Check "$Name is drawn" ($t[0] -ge 0.45 -and $t[1] -le 0.25) ("dark {0:P0}, light {1:P0}" -f $t[0], $t[1])
    $l = $Notch.X + 1; $t = $Notch.Y + 1; $r = $Notch.X + $Notch.W - 2; $b = $Notch.Y + $Notch.H - 2
    $corners = @(@($l, $t), @($r, $t), @($l, $b), @($r, $b))
    $pale = @($corners | Where-Object { [E2E]::Pale($_[0], $_[1]) }).Count
    Check "$Name has no pale box around it" ($pale -eq 0) "$pale of 4 corners pale"
}

# Films the screen at half size while $Action runs; fails on a short-lived white patch or a captioned GpuVM window.
function Check-NoFlash([string]$Name, [scriptblock]$Action, [int]$Milliseconds = 2500) {
    $s = Screen
    $half = { $f = Grab $s.X $s.Y $s.Width $s.Height; $x = [Drawing.Bitmap]::new($f, [int]($s.Width / 2), [int]($s.Height / 2)); $f.Dispose(); $x }
    $frames = [System.Collections.Generic.List[System.Drawing.Bitmap]]::new()
    $frames.Add((& $half))
    $app = Get-App
    & $Action
    $sw = [Diagnostics.Stopwatch]::StartNew(); $captions = 0
    while ($sw.ElapsedMilliseconds -lt $Milliseconds) { $frames.Add((& $half)); if ($app) { $captions = [Math]::Max($captions, [E2E]::Captioned([uint32]$app.Id)) } }
    $raw = @($frames | ForEach-Object { , (Bytes $_) })
    $stride = [int]($s.Width / 2) * 4
    $worst = 0; $at = -1; $dark = 0; $darkAt = -1
    for ($i = 1; $i -lt $frames.Count - 2; $i++) {
        $f = [E2E]::Flash($raw[$i - 1], $raw[$i], $raw[$i + 2], $stride)
        if ($f -gt $worst) { $worst = $f; $at = $i }
        $k = [E2E]::FlashBlack($raw[$i - 1], $raw[$i], $raw[$i + 2], $stride)
        if ($k -gt $dark) { $dark = $k; $darkAt = $i }
    }
    if ($at -ge 0) { $frames[$at].Save((Join-Path $script:Out "$($Name -replace '\W','-')-worst.png")) }
    if ($darkAt -ge 0) { $frames[$darkAt].Save((Join-Path $script:Out "$($Name -replace '\W','-')-black.png")) }
    $frames | ForEach-Object { $_.Dispose() }
    Check "$Name flashes nothing white" ($worst -lt 12) "$($frames.Count) frames, largest short-lived pale patch $worst blocks"
    Check "$Name flashes nothing black" ($dark -lt 40) "largest short-lived black patch $dark blocks"
    Check "$Name shows no GpuVM title bar" ($captions -eq 0) "$captions captioned window(s)"
}

# ---------- an agent: an MCP session of GpuVM's own server

function Start-Mcp([string]$Exe = 'C:\Program Files\GpuVM\gpuvm.exe', [string]$Name = 'E2e') {
    $psi = [Diagnostics.ProcessStartInfo]::new($Exe, '--mcp')
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $p = [Diagnostics.Process]::Start($psi)
    $s = [pscustomobject]@{ Process = $p; Id = 0 }
    Send-Mcp $s 'initialize' @{ protocolVersion = '2025-06-18'; capabilities = @{}; clientInfo = @{ name = $Name; version = '1' } } | Out-Null
    Send-Mcp $s 'notifications/initialized' $null -Notify
    $s
}

function Send-Mcp($Session, [string]$Method, $Params, [switch]$Notify, [switch]$NoWait) {
    $msg = [ordered]@{ jsonrpc = '2.0'; method = $Method }
    if ($null -ne $Params) { $msg.params = $Params }
    if (-not $Notify) { $Session.Id++; $msg.id = $Session.Id }
    $Session.Process.StandardInput.WriteLine(($msg | ConvertTo-Json -Depth 10 -Compress)); $Session.Process.StandardInput.Flush()
    if ($Notify) { return }
    if ($NoWait) { return $Session.Id }
    Receive-Mcp $Session $Session.Id
}

function Receive-Mcp($Session, [int]$Id) {
    while ($true) {
        $line = $Session.Process.StandardOutput.ReadLine()
        if ($null -eq $line) { throw 'The MCP server closed.' }
        $r = $line | ConvertFrom-Json
        if ($r.id -eq $Id) { return $r }
    }
}

function Text-Of($Reply) { (@($Reply.result.content) | Where-Object type -eq 'text' | ForEach-Object text) -join ' ' }

function Invoke-Tool($Session, [string]$Name, [hashtable]$Arguments = @{}) { Text-Of (Send-Mcp $Session 'tools/call' @{ name = $Name; arguments = $Arguments }) }

function Start-Tool($Session, [string]$Name, [hashtable]$Arguments = @{}) { Send-Mcp $Session 'tools/call' @{ name = $Name; arguments = $Arguments } -NoWait }

# The shared disposable machine, created by the agent session and open in the viewer for the person.
function Use-Machine($Ctx) {
    if (-not $Ctx.Machine) {
        $created = Invoke-Tool $Ctx.Mcp 'create_disposable' @{ template = $Ctx.Template; task = 'End-to-end suite' }
        $Ctx.Machine = [regex]::Match($created, "$($Ctx.Template)-[0-9a-f]{6}").Value
        Check 'agent creates a disposable machine' ([bool]$Ctx.Machine) $created
        if (-not $Ctx.Machine) { throw 'No machine to test on.' }
    }
    $opened = Invoke-Tool $Ctx.Mcp 'open_viewer' @{ machine = $Ctx.Machine; waitSeconds = 180 }
    if ($opened -notmatch 'now sees|already shows') { Check 'agent opens the viewer' $false $opened; throw "The viewer didn't open: $opened" }
    $Ctx.Machine
}

function Stop-Mcp($Session) { try { $Session.Process.StandardInput.Close(); $null = $Session.Process.WaitForExit(5000) } catch { } }

Export-ModuleMember -Function * -Variable Results
