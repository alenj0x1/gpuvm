# The tray (close to tray, its icon and menu), stopping and starting the service from Settings, and notices-only mode
# after quitting with a machine on; ends with GpuVM relaunched and every setting put back.
if (-not ('E2ETN' -as [type])) {
    Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class E2ETN {
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string name);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string name);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint f, IntPtr e);
  delegate bool EnumProc(IntPtr h, IntPtr l);
  public static IntPtr Find(string cls) { return FindWindow(cls, null); }
  public static bool Front(IntPtr h) {
    if (GetForegroundWindow() == h) return true;
    if (IsIconic(h)) ShowWindow(h, 9);
    keybd_event(0x12, 0, 0, IntPtr.Zero); keybd_event(0x12, 0, 2, IntPtr.Zero);
    SetForegroundWindow(h); System.Threading.Thread.Sleep(250);
    return GetForegroundWindow() == h;
  }
  public static void Key(byte vk) { keybd_event(vk, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(40); keybd_event(vk, 0, 2, IntPtr.Zero); }
  public static void RightClick(int x, int y) {
    SetCursorPos(x - 30, y - 20); System.Threading.Thread.Sleep(80);
    for (int i = 1; i <= 6; i++) { SetCursorPos(x - 30 + 5 * i, y - 20 + (20 * i) / 6); System.Threading.Thread.Sleep(15); }
    System.Threading.Thread.Sleep(150); mouse_event(8, 0, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(40); mouse_event(16, 0, 0, 0, IntPtr.Zero);
  }
  static IntPtr Notify() { return FindWindowEx(FindWindow("Shell_TrayWnd", null), IntPtr.Zero, "TrayNotifyWnd", null); }
  // The toolbar of icons next to the clock ("User Promoted Notification Area").
  public static IntPtr Promoted() { return FindWindowEx(FindWindowEx(Notify(), IntPtr.Zero, "SysPager", null), IntPtr.Zero, "ToolbarWindow32", null); }
  public static IntPtr OverflowWindow() { return FindWindow("NotifyIconOverflowWindow", null); }
  public static IntPtr Overflow() { return FindWindowEx(OverflowWindow(), IntPtr.Zero, "ToolbarWindow32", null); }
  public static IntPtr Chevron() { return FindWindowEx(Notify(), IntPtr.Zero, "Button", null); }
  public static IntPtr Menu() {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => { var c = new StringBuilder(64); GetClassName(h, c, 64); if (c.ToString() == "#32768" && IsWindowVisible(h)) { found = h; return false; } return true; }, IntPtr.Zero);
    return found;
  }
}
'@
}

$script:TnPid = 0
$script:TnMain = [IntPtr]::Zero

function Find-TnAll($Root, [string]$Type = '', [string]$Pattern = '', [string]$Class = '') {
    if (-not $Root) { return @() }
    $cond = if ($Type) { [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::$Type) } else { [Windows.Automation.Condition]::TrueCondition }
    try { @($Root.FindAll([Windows.Automation.TreeScope]::Descendants, $cond) | Where-Object { $c = $_.Current; $c.Name -match $Pattern -and (-not $Class -or $c.ClassName -match $Class) }) } catch { @() }
}

function Find-TnOne($Root, [string]$Type = '', [string]$Pattern = '', [string]$Class = '') { Find-TnAll $Root $Type $Pattern $Class | Select-Object -First 1 }

function Get-TnMain {
    if ($script:TnMain -ne [IntPtr]::Zero -and [E2ETN]::IsWindow($script:TnMain)) { return $script:TnMain }
    $app = Get-App
    if ($app) { $script:TnPid = $app.Id; $script:TnMain = $app.MainWindowHandle; return $script:TnMain }
    [IntPtr]::Zero
}

function Get-TnMainEl { $h = Get-TnMain; if ($h -ne [IntPtr]::Zero) { Get-Element $h } }

function Show-TnMain {
    $h = Get-TnMain
    if ($h -eq [IntPtr]::Zero) { return $false }
    if (-not [E2ETN]::IsWindowVisible($h)) { $null = [E2ETN]::ShowWindow($h, 5) }
    [E2ETN]::Front($h)
}

function Test-TnOn($El) {
    if (-not $El) { return $false }
    try { if ($El.Current.ClassName -match '\bon\b') { return $true } } catch { return $false }
    $p = $null
    try { if ($El.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { return $p.Current.IsSelected } } catch { }
    $false
}

# A real click on the element; when something else is over it, it is invoked instead and the result says so.
function Press-TnReal($El) {
    if (-not $El) { return $false }
    $p = $null
    try { if ($El.TryGetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern, [ref]$p)) { $p.ScrollIntoView(); Start-Sleep -Milliseconds 250 } } catch { }
    $null = Show-TnMain
    if (Click-Element $El) { return $true }
    try { $null = Invoke-Element $El } catch { }
    $false
}

function Get-TnRadio([string]$Pattern) { Find-TnOne (Get-TnMainEl) 'RadioButton' $Pattern }

function Read-TnRadio([string[]]$Patterns) {
    foreach ($x in $Patterns) { if (Test-TnOn (Get-TnRadio $x)) { return $x } }
    $null
}

function Select-TnRadio([string]$Pattern) {
    if (-not $Pattern) { return $false }
    $r = Wait-For { Get-TnRadio $Pattern } 3
    if (-not $r) { return $false }
    if (Test-TnOn $r) { return $true }
    $null = Press-TnReal $r
    [bool](Wait-For { Test-TnOn (Get-TnRadio $Pattern) } 3)
}

function Get-TnLabel([string]$Pattern) { ($Pattern -replace '[\^\$\(\)]', '') -replace '\|', ' / ' }

function Exit-TnViewer {
    $back = Find-TnOne (Get-TnMainEl) '' '' '\btitlebar-back\b'
    if ($back) {
        $null = Wait-For { $b = Find-TnOne (Get-TnMainEl) '' '' '\btitlebar-back\b'; -not $b -or $b.Current.IsEnabled } 15
        try { $null = Invoke-Element $back } catch { }
        $null = Wait-For { -not (Find-TnOne (Get-TnMainEl) '' '' '\btitlebar-back\b') } 10
    }
    $null = Show-TnMain
}

function Open-TnSettings([string]$Tab) {
    Exit-TnViewer
    $side = Wait-For { Find-TnOne (Get-TnMainEl) 'Button' '^(Settings|Ajustes)$' '\bside-item\b' } 10
    if (-not $side) { return $false }
    $null = Press-TnReal $side
    $t = Wait-For { Find-TnOne (Get-TnMainEl) 'TabItem' $Tab '\bpref-nav-item\b' } 5
    if (-not $t) { return $false }
    if ($t.Current.ClassName -notmatch '\bon\b') { $null = Press-TnReal $t }
    [bool](Wait-For { $x = Find-TnOne (Get-TnMainEl) 'TabItem' $Tab '\bpref-nav-item\b'; $x -and $x.Current.ClassName -match '\bon\b' } 3)
}

function Wait-TnReply($Session, [int]$Id, [double]$Seconds) {
    if ($Session.PSObject.Properties.Name -notcontains 'Pending') { $Session | Add-Member -NotePropertyName Pending -NotePropertyValue $null }
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ($true) {
        if (-not $Session.Pending) { $Session.Pending = $Session.Process.StandardOutput.ReadLineAsync() }
        $left = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
        if (-not $Session.Pending.Wait($left)) { return $null }
        $line = $Session.Pending.Result; $Session.Pending = $null
        if ($null -eq $line) { throw 'The MCP server closed.' }
        $r = $line | ConvertFrom-Json
        if ($r.id -eq $Id) { return $r }
    }
}

function Invoke-TnCall($Session, [string]$Name, [hashtable]$Arguments, [double]$Seconds = 60) {
    $r = Wait-TnReply $Session (Start-Tool $Session $Name $Arguments) $Seconds
    if ($null -eq $r) { '(no answer in time)' } elseif ($r.error) { "JSON-RPC error: $($r.error.message)" } else { Text-Of $r }
}

# ---------- the tray icon and its menu

# A toolbar taken with FromHandle shows no buttons; reached from the desktop's root it does (the overflow one only
# while it is open).
# A toolbar's buttons don't show under the toolbar element itself, only searched from the taskbar (or the overflow
# window, while it is open): they are taken from there and kept to the ones inside a notification area toolbar.
# Where the shell put GpuVM's icon, asked by its identity (the hidden tray_icon_app window and its id): UI Automation
# here lists the tray's buttons only as untyped panes.
if (-not ('E2ETNR' -as [type])) {
    Add-Type @'
using System; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class E2ETNR {
  [StructLayout(LayoutKind.Sequential)] struct NII { public uint cbSize; public IntPtr hWnd; public uint uID; public Guid guidItem; }
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
  [DllImport("shell32.dll")] static extern int Shell_NotifyIconGetRect(ref NII id, out RECT r);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string name);
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern int GetMenuItemCount(IntPtr m);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetMenuString(IntPtr m, uint item, System.Text.StringBuilder s, int n, uint flags);
  [DllImport("user32.dll")] static extern bool GetMenuItemRect(IntPtr h, IntPtr m, uint item, out RECT r);
  // The items of an open popup menu (its #32768 window): name and box of each, read through the menu itself.
  public static string[] MenuItems(IntPtr menuWindow) {
    var list = new List<string>();
    IntPtr m = SendMessage(menuWindow, 0x01E1, IntPtr.Zero, IntPtr.Zero);
    if (m == IntPtr.Zero) return list.ToArray();
    int n = GetMenuItemCount(m);
    for (uint i = 0; i < n && i < 32; i++) {
      var sb = new System.Text.StringBuilder(128); GetMenuString(m, i, sb, 128, 0x400);
      RECT r; if (!GetMenuItemRect(IntPtr.Zero, m, i, out r)) continue;
      list.Add(sb.ToString().Replace("&", "") + "|" + r.L + "|" + r.T + "|" + (r.R - r.L) + "|" + (r.B - r.T));
    }
    return list.ToArray();
  }
  public static int[] IconRect(uint pid) {
    var wins = new List<IntPtr>();
    foreach (var parent in new[] { IntPtr.Zero, new IntPtr(-3) }) {
      IntPtr a = IntPtr.Zero;
      for (int i = 0; i < 4096; i++) { a = FindWindowEx(parent, a, "tray_icon_app", null); if (a == IntPtr.Zero) break; uint p; GetWindowThreadProcessId(a, out p); if (p == pid) wins.Add(a); }
    }
    foreach (var h in wins) for (uint id = 0; id < 64; id++) {
      var n = new NII { cbSize = (uint)Marshal.SizeOf(typeof(NII)), hWnd = h, uID = id };
      RECT r; if (Shell_NotifyIconGetRect(ref n, out r) == 0 && r.R > r.L) return new[] { r.L, r.T, r.R - r.L, r.B - r.T };
    }
    return null;
  }
}
'@
}

function Get-TnTrayAll {
    # Every gpuvm process: with the window in the tray it has no title for Get-App to find it by.
    $r = $null
    foreach ($p in @(Get-Process gpuvm -ErrorAction SilentlyContinue)) { if (-not $r) { $r = [E2ETNR]::IconRect([uint32]$p.Id) } }
    if (-not $r) { return }
    $cx = $r[0] + $r[2] / 2; $cy = $r[1] + $r[3] / 2
    $inside = { param($h) if ($h -eq [IntPtr]::Zero -or -not [E2ETN]::IsWindowVisible($h)) { return $false }; $q = [E2E]::Rect($h); $cx -ge $q[0] -and $cx -le $q[0] + $q[2] -and $cy -ge $q[1] -and $cy -le $q[1] + $q[3] }
    $area = if (& $inside ([E2ETN]::Find('NotifyIconOverflowWindow'))) { 'hidden icons' } elseif (& $inside ([E2ETN]::Find('Shell_TrayWnd'))) { 'next to the clock' } else { '' }
    $current = [pscustomobject]@{ Name = 'GpuVM'; BoundingRectangle = [Windows.Rect]::new($r[0], $r[1], $r[2], $r[3]) }
    [pscustomobject]@{ Element = [pscustomobject]@{ Current = $current }; Area = $area; Toolbar = if ($area) { 'Notification Area' } else { '' } }
}

function Get-TnTrayButtons { Get-TnTrayAll | Where-Object { $_.Toolbar } }

function Find-TnTrayIcon { Get-TnTrayButtons | Where-Object { $_.Element.Current.Name -match '^GpuVM' } | Select-Object -First 1 }

function Get-TnTrayNames {
    $all = @(Get-TnTrayAll)
    if (-not $all.Count) { 'the shell knows no GpuVM icon' } else { "GpuVM icon at $($all[0].Element.Current.BoundingRectangle), area: '$($all[0].Area)'" }
}

function Show-TnTrayIcon {
    $i = Find-TnTrayIcon
    if (-not $i -and -not [E2ETN]::IsWindowVisible([E2ETN]::OverflowWindow())) {
        $c = [E2ETN]::Chevron()
        $r = if ($c -ne [IntPtr]::Zero) { [E2E]::Rect($c) } else { @(0, 0, 0, 0) }
        if ($r[2] -gt 4 -and [E2ETN]::IsWindowVisible($c)) {
            [E2E]::Click($r[0] + [int]($r[2] / 2), $r[1] + [int]($r[3] / 2))
            $null = Wait-For { [E2ETN]::IsWindowVisible([E2ETN]::OverflowWindow()) } 3
            Start-Sleep -Milliseconds 300
        }
        $i = Find-TnTrayIcon
    }
    $i
}

function Get-TnMenu {
    $h = [E2ETN]::Menu()
    if ($h -eq [IntPtr]::Zero) { return $null }
    # UI Automation shows a classic menu's items as untyped panes here: they are read through the menu.
    $items = @([E2ETNR]::MenuItems($h) | Where-Object { $_ } | ForEach-Object {
        $f = $_ -split '\|'
        $current = [pscustomobject]@{ Name = $f[0]; BoundingRectangle = [Windows.Rect]::new([double]$f[1], [double]$f[2], [double]$f[3], [double]$f[4]) }
        [pscustomobject]@{ Current = $current }
    })
    if (-not $items.Count) { return $null }
    [pscustomobject]@{ Root = $null; Items = $items; Names = @($items | ForEach-Object { $_.Current.Name }) }
}

function Open-TnTrayMenu {
    for ($try = 0; $try -lt 2; $try++) {
        $i = Show-TnTrayIcon
        if (-not $i) { Start-Sleep -Seconds 1; continue }
        $r = $i.Element.Current.BoundingRectangle
        if ($r.Width -le 0) { Start-Sleep -Milliseconds 500; continue }
        [E2ETN]::RightClick([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2))
        $m = Wait-For { Get-TnMenu } 4
        if ($m) { return $m }
        [E2ETN]::Key(0x1B)
    }
    $null
}

function Close-TnMenu { if (Get-TnMenu) { [E2ETN]::Key(0x1B); $null = Wait-For { -not (Get-TnMenu) } 3 } }

function Press-TnMenuItem($Item) {
    if (Click-Element $Item 'gpuvm') { return $true }
    try { $null = Invoke-Element $Item } catch { }
    $false
}

# ---------- the checks

function Test-TnTray {
    $windowTab = '^(Window|Ventana)$'
    $trayRe = '^(Stay in the tray|Quedarse en la bandeja)$'
    $quitRe = '^(Quit completely|Salir por completo)$'
    if (-not (Open-TnSettings $windowTab)) { Check 'Settings > Window opens' $false ''; return }
    $orig = Read-TnRadio @($quitRe, $trayRe)
    Check 'the close setting is readable' ([bool]$orig) "selected: $orig"
    if (-not $orig) { return }
    $h = Get-TnMain
    $procId = $script:TnPid
    try {
        Check '"Stay in the tray" is selected' (Select-TnRadio $trayRe) ''
        $null = Press-TnReal (Find-TnOne (Get-TnMainEl) 'Button' '' '\bwin-close\b')
        $hid = Wait-For { -not [E2ETN]::IsWindowVisible($h) } 8
        $alive = [bool](Get-Process -Id $procId -ErrorAction SilentlyContinue)
        Check 'in the tray: the close button hides the window and GpuVM keeps running' ([bool]$hid -and $alive) "hidden: $([bool]$hid), running: $alive"
        $icon = Wait-For { Show-TnTrayIcon } 8
        Check 'the tray icon is in the notification area, not on the taskbar' ([bool]$icon) $(if ($icon) { "$($icon.Area) ($($icon.Toolbar)): $($icon.Element.Current.Name)" } else { "no GpuVM button in the notification area toolbars; buttons there: $(Get-TnTrayNames)" })
        Shot 'tray-hidden'
        if (-not $icon) { return }
        $i = Show-TnTrayIcon
        $clicked = $i -and (Click-Element $i.Element 'explorer')
        $back = Wait-For { [E2ETN]::IsWindowVisible($h) } 8
        Check 'a left click on the tray icon brings the window back' ($clicked -and [bool]$back) "clicked: $clicked"
        $menu = Open-TnTrayMenu
        $names = if ($menu) { $menu.Names } else { @() }
        $hasOpen = @($names | Where-Object { $_ -match '^(Open GpuVM|Abrir GpuVM)$' }).Count -gt 0
        $hasQuit = @($names | Where-Object { $_ -match '^(Quit|Salir)$' }).Count -gt 0
        Check 'a right click on the tray icon shows Open GpuVM and Quit' ($hasOpen -and $hasQuit) ($names -join ', ')
        Shot 'tray-menu'
        Close-TnMenu
    }
    finally {
        Close-TnMenu
        if (-not [E2ETN]::IsWindowVisible($h)) { $null = [E2ETN]::ShowWindow($h, 5) }
        $null = Open-TnSettings $windowTab
        Check "closing the window goes back to $(Get-TnLabel $orig)" (Select-TnRadio $orig) ''
    }
}

# The state's span has no box in UI Automation: its text is one of the states. With the service stopped, the whole
# window shows a "service is stopped" page with its own Start service button instead of Settings.
function Get-TnServiceState {
    $root = Get-TnMainEl
    if (Find-TnOne $root 'Text' '^(The GpuVM service is stopped|El servicio de GpuVM está detenido)$') { return 'Stopped (the stopped-service page)' }
    $e = Find-TnOne $root '' '' '\bpref-state\b'
    if (-not $e) { $e = Find-TnOne $root 'Text' '^(Running|Stopped|Starting…|Stopping…|Not installed|En marcha|Detenido|Iniciando…|Deteniendo…|No instalado)$' }
    if (-not $e) { return '' }
    if ($e.Current.Name) { $e.Current.Name } else { Get-Texts $e }
}

function Find-TnStart { Find-TnOne (Get-TnMainEl) 'Button' '^(Start service|Iniciar servicio|Start|Iniciar)$' }

function Test-TnService($Ctx) {
    $list = Invoke-TnCall $Ctx.Mcp 'list_machines' @{} 30
    $others = @()
    foreach ($line in ($list -split "`r?`n")) {
        $m = [regex]::Match($line, '^- (.+?): ([^,\s]+)')
        if ($m.Success -and $m.Groups[1].Value -ne $Ctx.Machine -and $m.Groups[2].Value -ne 'off') { $others += "$($m.Groups[1].Value) ($($m.Groups[2].Value))" }
    }
    if ($others.Count) { Check 'service Stop and Start: skipped, other machines are running' $false ($others -join ', '); return }
    if (-not (Open-TnSettings '^(Service|Servicio)$')) { Check 'Settings > Service opens' $false ''; return }
    $modes = @('^(With GpuVM|Con GpuVM)$', '^(With Windows|Con Windows)$', '^Manual$')
    $orig = Read-TnRadio $modes
    Check 'the service mode is readable' ([bool]$orig) "selected: $orig"
    if (-not $orig) { return }
    if ($orig -eq $modes[1]) { Check 'service Stop and Start: skipped, the service starts with Windows and switching to Manual needs administrator permission' $false ''; return }
    $stopped = $false
    try {
        Check '"Manual" is selected so Stop and Start show' (Select-TnRadio $modes[2]) ''
        $stop = Wait-For { Find-TnOne (Get-TnMainEl) 'Button' '^(Stop|Detener)$' '^btn\b' } 5
        $null = Press-TnReal $stop
        $stopped = $true
        $ui = Wait-For { $s = Get-TnServiceState; if ($s -match 'Stopped|Detenido') { $s } } 30
        $svc = Wait-For { (Get-Service GpuVM -ErrorAction SilentlyContinue).Status -eq 'Stopped' } 10
        Check 'Stop: GpuVM shows the service Stopped' ([bool]$ui) "GpuVM: $(Get-TnServiceState)"
        Check 'Stop: Windows reports the GpuVM service Stopped' ([bool]$svc) "Get-Service: $((Get-Service GpuVM -ErrorAction SilentlyContinue).Status)"
        Shot 'service-stopped'
        $start = Wait-For { Find-TnStart } 5
        $null = Press-TnReal $start
        $svc = Wait-For { (Get-Service GpuVM -ErrorAction SilentlyContinue).Status -eq 'Running' } 40
        Check 'Start: Windows reports the GpuVM service Running' ([bool]$svc) "Get-Service: $((Get-Service GpuVM -ErrorAction SilentlyContinue).Status); pressed: $(if ($start) { $start.Current.Name } else { 'no Start button' })"
        $null = Open-TnSettings '^(Service|Servicio)$'
        $ui = Wait-For { $s = Get-TnServiceState; if ($s -match 'Running|En marcha') { $s } } 30
        Check 'Start: Settings shows the service Running' ([bool]$ui) "Settings: $(Get-TnServiceState)"
    }
    finally {
        if ((Get-Service GpuVM -ErrorAction SilentlyContinue).Status -ne 'Running') {
            $b = Find-TnStart
            if ($b) { try { $null = Invoke-Element $b } catch { } }
            if (-not (Wait-For { (Get-Service GpuVM -ErrorAction SilentlyContinue).Status -eq 'Running' } 30)) { try { Start-Service GpuVM } catch { } }
        }
        $null = Open-TnSettings '^(Service|Servicio)$'
        Check "the service mode goes back to $(Get-TnLabel $orig)" (Select-TnRadio $orig) "service: $((Get-Service GpuVM -ErrorAction SilentlyContinue).Status)"
        # Stopping the service ends every agent connection: the suite's agent connects again.
        if ($stopped) {
            Stop-Mcp $Ctx.Mcp
            try { $Ctx.Mcp = Start-Mcp $Ctx.Exe } catch { Write-Host "     the agent couldn't connect again: $($_.Exception.Message)" }
            if ($Ctx.Machine) { $t = Invoke-TnCall $Ctx.Mcp 'take_machine' @{ machine = $Ctx.Machine; waitSeconds = 60; task = 'End-to-end suite' } 90; Write-Host "     the agent takes $($Ctx.Machine) again: $t" }
        }
    }
}

function Test-TnNoticesOnly($Ctx) {
    $windowTab = '^(Window|Ventana)$'
    $trayRe = '^(Stay in the tray|Quedarse en la bandeja)$'
    $quitRe = '^(Quit completely|Salir por completo)$'
    $leaveRe = '^(Leave them on|Dejarlas encendidas)$'
    $shutRe = '^(Shut them down|Apagarlas)$'
    $showRe = '^(Show them|Mostrarlos)$'
    $hideRe = "^(Don't show them|No mostrarlos)$"
    $null = Use-Machine $Ctx
    if (-not (Open-TnSettings $windowTab)) { Check 'Settings > Window opens' $false ''; return }
    $origClose = Read-TnRadio @($quitRe, $trayRe)
    $origVms = Read-TnRadio @($leaveRe, $shutRe)
    Check 'the window settings are readable' ($origClose -and $origVms) "closing: $origClose, machines on quit: $origVms"
    if (-not ($origClose -and $origVms)) { return }
    $origNotices = $null
    $procId = $script:TnPid
    $quitPressed = $false
    try {
        $ok = (Select-TnRadio $trayRe) -and (Select-TnRadio $leaveRe)
        if ($ok) { $null = Wait-For { Get-TnRadio $showRe } 3; $origNotices = Read-TnRadio @($showRe, $hideRe); $ok = Select-TnRadio $showRe }
        Check 'set up: stay in the tray, leave machines on, show administrator prompts after quitting' $ok ''
        if (-not $ok -or -not (Test-TnOn (Get-TnRadio $leaveRe))) { return }

        $menu = Open-TnTrayMenu
        $quit = if ($menu) { $menu.Items | Where-Object { $_.Current.Name -match '^(Quit|Salir)$' } | Select-Object -First 1 }
        Check 'the tray menu offers Quit' ([bool]$quit) $(if ($menu) { $menu.Names -join ', ' } else { 'no menu' })
        if (-not $quit) { Close-TnMenu; return }
        $quitPressed = $true
        $null = Press-TnMenuItem $quit
        $h = $script:TnMain
        $gone = Wait-For { -not [E2ETN]::IsWindow($h) -or -not [E2ETN]::IsWindowVisible($h) } 15
        Start-Sleep -Seconds 1
        $alive = [bool](Get-Process -Id $procId -ErrorAction SilentlyContinue)
        Check 'Quit with a machine on: the main window goes and GpuVM keeps running' ([bool]$gone -and $alive) "window gone: $([bool]$gone), running: $alive"
        if (-not $alive) { return }
        Start-Sleep -Seconds 1
        $menu = Open-TnTrayMenu
        $stopItem = if ($menu) { $menu.Items | Where-Object { $_.Current.Name -match '^(Stop watching and quit|Dejar de vigilar y salir)$' } | Select-Object -First 1 }
        Check 'notices-only mode: the tray menu offers "Stop watching and quit"' ([bool]$stopItem) $(if ($menu) { $menu.Names -join ', ' } else { 'no menu' })
        Shot 'tray-notices-only'
        if (-not $stopItem) { Close-TnMenu; return }
        $null = Press-TnMenuItem $stopItem
        $ended = Wait-For { -not (Get-Process -Id $procId -ErrorAction SilentlyContinue) } 15
        Check '"Stop watching and quit" ends GpuVM' ([bool]$ended) ''
    }
    finally {
        Close-TnMenu
        if ($quitPressed) {
            # Through Explorer, as the person opens it: started from this elevated shell it would run elevated.
            Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$($Ctx.Exe)`""
            $app = Wait-For { Get-App } 60
            Check 'GpuVM opens again' ([bool]$app) ''
            $script:TnMain = [IntPtr]::Zero
            if ($app) { $script:TnPid = $app.Id; $script:TnMain = $app.MainWindowHandle; $null = Wait-For { Find-TnOne (Get-TnMainEl) 'Button' '^(Settings|Ajustes)$' '\bside-item\b' } 20 }
        }
        if ((Get-App) -and (Open-TnSettings $windowTab)) {
            $r = $true
            if ($origNotices) { $r = (Select-TnRadio $leaveRe) -and (Select-TnRadio $origNotices) }
            $r = $r -and (Select-TnRadio $origVms) -and (Select-TnRadio $origClose)
            Check 'the window settings go back to what they were' $r "closing: $(Get-TnLabel $origClose), machines on quit: $(Get-TnLabel $origVms), prompts: $(Get-TnLabel $origNotices)"
        }
        else { Check 'the window settings go back to what they were' $false 'GpuVM or its Settings did not open' }
    }
}

function Test-Suite($Ctx) {
    # The service is stopped and started on purpose (Settings > Service): the app says so while it is.
    $script:ExpectedErrors = @('The GpuVM service is stopped')
    $app = Get-App
    if (-not $app) { throw 'GpuVM is not running.' }
    $script:TnPid = $app.Id; $script:TnMain = $app.MainWindowHandle
    foreach ($step in @(@{ Name = 'tray'; Body = { Test-TnTray } }, @{ Name = 'service'; Body = { Test-TnService $Ctx } }, @{ Name = 'notices-only mode'; Body = { Test-TnNoticesOnly $Ctx } })) {
        try { & $step.Body } catch { Check "$($step.Name) ran to the end" $false $_.Exception.Message }
        try { Close-TnMenu } catch { }
    }
    $null = Show-TnMain
}
