# What lives outside the main window: request notifications, the tray, the service, the viewer coming in front,
# app.log, the viewer's isolation and the templates.
if (-not ('E2ESys' -as [type])) {
    Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text; using System.Collections.Generic;
public static class E2ESys {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string name);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string name);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint f, IntPtr e);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint a, bool inherit, int pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] static extern bool GetProcessMitigationPolicy(IntPtr p, int policy, ref uint buf, IntPtr size);
  [DllImport("advapi32.dll")] static extern bool OpenProcessToken(IntPtr p, uint a, out IntPtr t);
  [DllImport("advapi32.dll")] static extern bool GetTokenInformation(IntPtr t, int c, IntPtr buf, int len, out int ret);
  [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthority(IntPtr sid, uint i);
  [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
  delegate bool EnumProc(IntPtr h, IntPtr l);

  public static void Front(IntPtr h) { keybd_event(0x12, 0, 0, IntPtr.Zero); SetForegroundWindow(h); keybd_event(0x12, 0, 2, IntPtr.Zero); }
  public static uint Pid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
  public static IntPtr[] VisibleOfClass(string cls) { var list = new List<IntPtr>(); EnumWindows((h, l) => { if (IsWindowVisible(h) && Cls(h) == cls) list.Add(h); return true; }, IntPtr.Zero); return list.ToArray(); }
  static string Cls(IntPtr h) { var c = new StringBuilder(256); GetClassName(h, c, 256); return c.ToString(); }
  public static string[] Classes(uint pid) {
    var list = new List<string>();
    EnumWindows((h, l) => { if (Pid(h) == pid) list.Add(Cls(h)); return true; }, IntPtr.Zero);
    IntPtr after = IntPtr.Zero;
    for (int i = 0; i < 4096; i++) { after = FindWindowEx(new IntPtr(-3), after, null, null); if (after == IntPtr.Zero) break; if (Pid(after) == pid) list.Add(Cls(after)); }
    return list.ToArray();
  }
  public static int Integrity(int pid) {
    IntPtr p = OpenProcess(0x1000, false, pid); if (p == IntPtr.Zero) return -1;
    try {
      IntPtr t; if (!OpenProcessToken(p, 8, out t)) return -2;
      try {
        int n; GetTokenInformation(t, 25, IntPtr.Zero, 0, out n); if (n <= 0) return -3;
        IntPtr buf = Marshal.AllocHGlobal(n);
        try {
          if (!GetTokenInformation(t, 25, buf, n, out n)) return -3;
          IntPtr sid = Marshal.ReadIntPtr(buf);
          int count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
          return Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(count - 1)));
        } finally { Marshal.FreeHGlobal(buf); }
      } finally { CloseHandle(t); }
    } finally { CloseHandle(p); }
  }
  public static long ImageLoadPolicy(int pid) {
    IntPtr p = OpenProcess(0x1400, false, pid); if (p == IntPtr.Zero) p = OpenProcess(0x1000, false, pid); if (p == IntPtr.Zero) return -1;
    try { uint v = 0; return GetProcessMitigationPolicy(p, 10, ref v, new IntPtr(4)) ? v : -2; } finally { CloseHandle(p); }
  }
}
'@
}

function Find-Class($Root, [string]$Class, [string]$Name = '') {
    if (-not $Root) { return $null }
    foreach ($e in $Root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)) {
        $c = $e.Current
        if ($c.ClassName -match $Class -and (-not $Name -or $c.Name -match $Name)) { return $e }
    }
    $null
}

function Press($Element) {
    if (-not $Element) { return $false }
    $p = $null
    if ($Element.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$p)) {
        try { $p.Invoke(); return $true } catch { Write-Host "     couldn't invoke '$($Element.Current.Name)': $($_.Exception.GetType().Name)"; return $false }
    }
    $r = $Element.Current.BoundingRectangle
    if ($r.Width -gt 0) { [E2E]::Click([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2)); return $true }
    Invoke-Element $Element
}

function Read-Log([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $fs = [IO.FileStream]::new($Path, 'Open', 'Read', 'ReadWrite')
    try { $r = [IO.StreamReader]::new($fs); , ($r.ReadToEnd() -split "`r?`n") } finally { $fs.Dispose() }
}

# A Windows toast (a CoreWindow of the shell) or a notification window of GpuVM's own over the desktop.
function Find-Toast([string]$Pattern) {
    # Its text isn't readable through this UI Automation client, nor is its window listed: the shell's toast is what
    # sits in the bottom-right corner above the taskbar.
    $screen = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    foreach ($dy in 70, 120) {
        $at = [E2E]::At($screen.Right - 200, $screen.Bottom - $dy)
        if ($at -eq 'ShellExperienceHost/Windows.UI.Core.CoreWindow') { return [pscustomobject]@{ Text = "toast in the bottom-right corner"; Owner = $at } }
    }
    $app = Get-App
    $own = @(Get-AppWindows | Where-Object { -not $app -or $_.Handle -ne $app.MainWindowHandle } | ForEach-Object { Get-Element $_.Handle } | Where-Object { $_ })
    foreach ($w in $own) {
        $text = try { "$($w.Current.Name) | $(Get-Texts $w)" } catch { '' }
        if ($text -notmatch $Pattern) { continue }
        # The dock over the picture shows the same title with its answers; it is not a notification.
        if ($text -match '(Refuse|Rechazar)') { continue }
        $owner = try { (Get-Process -Id ([E2ESys]::Pid([IntPtr]$w.Current.NativeWindowHandle))).ProcessName } catch { '?' }
        return [pscustomobject]@{ Text = $text; Owner = "$owner/$($w.Current.ClassName)" }
    }
    $null
}

function Test-ViewerAtCenter { $s = Screen; [E2E]::ProcessNameAt([int]($s.Width / 2), [int]($s.Height / 2)) -eq 'GpuVMViewer' }

# Home in the title bar is enabled once the picture is live; a picture that fills the monitor covers it, and there the
# person presses Ctrl+Alt+Shift+H.
function Go-Home($Main) {
    $back = Find-Class $Main '\btitlebar-back\b'
    if ($back) {
        $live = Wait-For { $b = Find-Class $Main '\btitlebar-back\b'; if ($b -and $b.Current.IsEnabled) { $b } } 30
        if ($live) { $back = $live } else { Write-Host '     Home in the title bar is still disabled (the picture is not live yet)' }
        if (-not (Click-Element $back)) {
            $v = Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
            for ($i = 0; $v -and $i -lt 3 -and [E2E]::Foreground() -notlike 'GpuVMViewer/*'; $i++) { [E2ESys]::Front($v.MainWindowHandle); Start-Sleep -Milliseconds 400 }
            Write-Host "     Ctrl+Alt+Shift+H with $([E2E]::Foreground()) in front"
            [E2E]::Combo([byte][char]'H')
        }
        return [bool](Wait-For { -not (Test-ViewerAtCenter) } 10)
    }
    $side = Find-Class $Main '\bside-home\b' '^(Home|Inicio)$'
    if ($side) { $null = Press $side }
    -not (Test-ViewerAtCenter)
}

function Test-Suite($Ctx) {
    $app = Get-App
    if (-not $app) { throw 'GpuVM is not running.' }
    $hMain = $app.MainWindowHandle
    $main = Get-Element $hMain
    $log = Join-Path $env:LOCALAPPDATA 'GpuVM\app.log'
    $logStart = (Read-Log $log).Count
    $s = Screen
    $cx = [int]($s.Width / 2); $cy = [int]($s.Height / 2)
    $notepad = $null

    try {
        $svc = Get-Service -Name GpuVM -ErrorAction SilentlyContinue
        Check 'the GpuVM service is running' ($svc -and $svc.Status -eq 'Running') "status: $(if ($svc) { $svc.Status } else { 'not installed' })"

        $templates = Invoke-Tool $Ctx.Mcp 'list_templates'
        Check "list_templates shows $($Ctx.Template)" ($templates -match "(?m)^- $([regex]::Escape($Ctx.Template)) ") ($templates -replace '\s+', ' ')
        $tplDir = Join-Path 'C:\GpuVM\.templates' $Ctx.Template
        $failed = Join-Path $tplDir 'update-failed.json'
        $detail = if (-not (Test-Path (Join-Path $tplDir 'template.json'))) { "no template.json in $tplDir" }
                  elseif (Test-Path $failed) { "last update failed: $((Get-Content -Raw $failed) -replace '\s+', ' ')" }
                  else { "built $((Get-Item (Join-Path $tplDir 'template.json')).LastWriteTime.ToString('yyyy-MM-dd HH:mm'))" }
        Check "$($Ctx.Template) is current (no failed update)" ((Test-Path (Join-Path $tplDir 'template.json')) -and -not (Test-Path $failed)) $detail

        $vm = Use-Machine $Ctx
        $viewers = @(Get-Process GpuVMViewer -ErrorAction SilentlyContinue)
        Check 'the viewer is running' ($viewers.Count -gt 0) "$($viewers.Count) viewer process(es)"
        foreach ($v in $viewers) {
            $il = [E2ESys]::Integrity($v.Id)
            Check "viewer $($v.Id) runs at Low integrity" ($il -eq 0x1000) ('integrity 0x{0:X}' -f $il)
            $policy = [E2ESys]::ImageLoadPolicy($v.Id)
            Check "viewer $($v.Id) refuses remote and Low-label DLLs" ($policy -ge 0 -and ($policy -band 3) -eq 3) ('image-load policy 0x{0:X}' -f $policy)
        }

        Check 'Home hides the picture' (Go-Home $main) "at the center: $([E2E]::ProcessNameAt($cx, $cy))"

        $notepad = Start-Process notepad.exe -PassThru
        $null = $notepad.WaitForInputIdle(10000)
        $hNote = Wait-For { $notepad.Refresh(); if ($notepad.MainWindowHandle -ne [IntPtr]::Zero) { $notepad.MainWindowHandle } } 10
        if ($hNote) {
            $null = [E2ESys]::MoveWindow($hNote, $cx - 450, $cy - 300, 900, 600, $true)
            [E2ESys]::Front($hNote)
            Start-Sleep -Milliseconds 800
        }
        Check 'notepad is in front before open_viewer' ([E2E]::ProcessNameAt($cx, $cy) -eq 'notepad') "at the center: $([E2E]::ProcessNameAt($cx, $cy)), focus: $([E2E]::Foreground())"
        $opened = Invoke-Tool $Ctx.Mcp 'open_viewer' @{ machine = $vm; waitSeconds = 60 }
        $front = Wait-For { Test-ViewerAtCenter } 10
        Check 'open_viewer brings the picture in front of notepad' ([bool]$front) "at the center: $([E2E]::ProcessNameAt($cx, $cy)); $opened"
        Check 'notepad keeps the keyboard focus' ([E2E]::Foreground() -match '^notepad/') "focus: $([E2E]::Foreground())"
        Shot 'system-1-open-viewer'

        $null = Go-Home $main
        $null = [E2ESys]::ShowWindow($hMain, 6)
        if ($hNote) { [E2ESys]::Front($hNote) }
        Start-Sleep -Seconds 1
        # A notification left on screen (Windows keeps a reminder until it is clicked) would answer for this one.
        $screen = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        for ($i = 0; $i -lt 3 -and (Find-Toast '.'); $i++) { [E2E]::Click($screen.Right - 200, $screen.Bottom - 120); Start-Sleep -Seconds 2 }
        if ($hNote) { [E2ESys]::Front($hNote) }
        $title = "E2E notification check $(Get-Random -Maximum 99999)"
        $pattern = [regex]::Escape($title)
        $pending = Start-Tool $Ctx.Mcp 'request_approval' @{ machine = $vm; kind = 'other'; title = $title; reason = 'Checking the Windows notification.'; waitSeconds = 300 }
        $toast = Wait-For { Find-Toast $pattern } 15
        Check 'a Windows notification shows the request' ([bool]$toast) $(if ($toast) { "$($toast.Owner): $($toast.Text)" } else { 'no notification found' })
        Shot 'system-2-notification'
        if ($toast) {
            $missing = 0
            for ($i = 0; $i -lt 10; $i++) { Start-Sleep -Seconds 1; if (-not (Find-Toast $pattern)) { $missing++ } }
            Check 'the notification stays on screen for 10 s' ($missing -eq 0) "missing in $missing of 10 samples"
        }

        $null = [E2ESys]::ShowWindow($hMain, 9)
        [E2ESys]::Front($hMain)
        $agents = Wait-For { Find-Class $main '\bside-home\b' '^(Agents|Agentes)\b' } 5
        $null = Press $agents
        $findAllow = {
            # The Allow on the same line as the request's title: one read of the page (reading each button's
            # surroundings took long enough on a page with many recordings to let the request expire).
            # Right after the window comes forward, WebView2 rebuilds its accessibility tree and a read can time out.
            $all = try { @($main.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)) } catch { @() }
            $title = $all | Where-Object { $_.Current.Name -match $pattern -and $_.Current.ControlType -ne [Windows.Automation.ControlType]::Button } | Select-Object -First 1
            if ($title) {
                $ty = $title.Current.BoundingRectangle.Y + $title.Current.BoundingRectangle.Height / 2
                $all | Where-Object { $_.Current.ControlType -eq [Windows.Automation.ControlType]::Button -and $_.Current.Name -match '^\W*(Allow|Permitir)\W*$' -and [Math]::Abs(($_.Current.BoundingRectangle.Y + $_.Current.BoundingRectangle.Height / 2) - $ty) -lt 40 } | Select-Object -First 1
            }
        }
        $allow = Wait-For $findAllow 30
        Check 'the request shows on the Agents page' ([bool]$allow) ''
        # Answer buttons arm after a moment (disabled until then), as on the dock.
        $armed = $false
        if ($allow) {
            # Allow arms 0.8 s after the window gets the focus (a click already on its way never approves): a person's
            # click on the window in front, once it is armed.
            [E2ESys]::Front($hMain)
            Start-Sleep -Milliseconds 1200
            # Arming draws the button again: the one found before is stale, so it is looked for once more.
            $allow = Wait-For { $b = & $findAllow; if ($b -and (try { $b.Current.IsEnabled } catch { $false })) { $b } } 30
            $armed = [bool]$allow
            $null = Click-Element $allow
            Start-Sleep -Milliseconds 600; Shot 'system-allow-pressed'
        }
        $answer = Text-Of (Receive-Mcp $Ctx.Mcp $pending)
        Check 'Allow answers the agent' ($answer -match 'allowed') "$answer (button armed: $armed)"
        $gone = Wait-For { -not (Find-Toast $pattern) } 10
        Check 'the notification goes once answered' ([bool]$gone) ''
        Shot 'system-3-answered'

        $settings = Find-Class $main '\bside-foot\b'
        $null = Press $settings
        $tab = Wait-For { Find-Class $main '\bpref-nav-item\b' '(Service|Servicio)$' } 8
        $null = Press $tab
        $texts = Wait-For { $t = Get-Texts $main; if ($t -match 'Running|En marcha') { $t } } 8
        if (-not $texts) { $texts = Get-Texts $main }
        Check 'Settings shows the service running' ($texts -match 'Running|En marcha' -and $texts -notmatch 'Not installed|No instalado') ([regex]::Match($texts, '(Running|En marcha|Stopped|Detenido|Starting|Iniciando|Not installed|No instalado)[^|]*').Value)
        Shot 'system-4-service'

        $tab = Find-Class $main '\bpref-nav-item\b' '(Window|Ventana)$'
        $null = Press $tab
        $trayRadio = Wait-For { Find-Class $main '' '^(Stay in the tray|Quedarse en la bandeja)$' } 8
        $quitRadio = Find-Class $main '' '^(Quit completely|Salir por completo)$'
        $toTray = $trayRadio -and $trayRadio.Current.ClassName -match '\bon\b'
        $toQuit = $quitRadio -and $quitRadio.Current.ClassName -match '\bon\b'
        Check 'the close setting is readable' ($toTray -or $toQuit) "closing the window: $(if ($toTray) { 'stays in the tray' } elseif ($toQuit) { 'quits' } else { 'unknown' })"

        $classes = @([E2ESys]::Classes([uint32]$app.Id))
        $hidden = @($classes | Where-Object { $_ -match '^dev\.alejandro\.gpuvm|Tao|tray' } | Select-Object -Unique)
        Check 'GpuVM''s hidden event/tray window exists' ($hidden.Count -gt 0) ($hidden -join ', ')
        $area = foreach ($cls in 'Shell_TrayWnd', 'NotifyIconOverflowWindow') { $h = [E2ESys]::FindWindow($cls, $null); if ($h -ne [IntPtr]::Zero) { Get-Texts (Get-Element $h) } }
        $icon = ($area -join ' | ') -match 'GpuVM'
        if ($toTray) { Check 'the tray icon is in the notification area' $icon '' }
        else { Write-Host "INFO  tray icon in the notification area: $icon (close quits, so none is required)" }

        if ($toTray) {
            $close = Find-Class $main '\bwin-close\b'
            $null = Press $close
            $hid = Wait-For { -not [E2ESys]::IsWindowVisible($hMain) } 8
            $alive = [bool](Get-Process -Id $app.Id -ErrorAction SilentlyContinue)
            Check 'the close button hides GpuVM to the tray' ([bool]$hid -and $alive) "visible: $([E2ESys]::IsWindowVisible($hMain)), running: $alive"
            Start-Process -FilePath $Ctx.Exe
            $back = Wait-For { [E2ESys]::IsWindowVisible($hMain) } 15
            Check 'opening GpuVM again shows the window' ([bool]$back) ''
        }
        else { Write-Host 'INFO  close button not pressed: it would quit GpuVM' }

        $homeButton = Find-Class $main '\bside-home\b' '^(Home|Inicio)$'
        $null = Press $homeButton

        $lines = Read-Log $log
        Check 'app.log exists' (Test-Path -LiteralPath $log) $log
        $runStart = (Get-Item -LiteralPath $Ctx.Out).CreationTime
        # The app logs only what goes wrong, so a clean suite may add nothing: the running GpuVM's own start line
        # shows the log is the live one.
        $mine = @($lines | Where-Object { $_ -match "^---- GpuVM .* started \(pid $($app.Id)\)" }).Count -gt 0
        $grew = ($lines.Count -gt $logStart) -or ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).LastWriteTime -gt $runStart) -or $mine
        Check 'app.log is written by the running GpuVM' $grew "$($lines.Count - $logStart) line(s) in this suite, last written $((Get-Item -LiteralPath $log -ErrorAction SilentlyContinue).LastWriteTime), start line of pid $($app.Id): $mine"
        $session = $lines
        $startAt = -1
        for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match '^---- GpuVM .* started') { $startAt = $i; break } }
        if ($startAt -ge 0) { $session = $lines[$startAt..($lines.Count - 1)] }
        $panics = @($session | Where-Object { $_ -match 'panicked' })
        Check 'app.log has no panic since GpuVM started' ($panics.Count -eq 0) $(if ($panics) { $panics[0] } else { "$($session.Count) line(s)" })
    }
    finally {
        if ($notepad -and -not $notepad.HasExited) { Stop-Process -Id $notepad.Id -Force -ErrorAction SilentlyContinue }
        if ($hMain) {
            if (-not [E2ESys]::IsWindowVisible($hMain)) { $null = [E2ESys]::ShowWindow($hMain, 5) }
            if ([E2ESys]::IsIconic($hMain)) { $null = [E2ESys]::ShowWindow($hMain, 9) }
        }
    }
}
