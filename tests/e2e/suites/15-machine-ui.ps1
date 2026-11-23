# A machine's life driven from the app with real clicks: a disposable opened from the Library, its power menu, an
# agent's disposable with set resources kept as a regular machine, its restore points, rename and Customize.
if (-not ('MU15' -as [type])) {
    Add-Type @'
using System; using System.Runtime.InteropServices;
public static class MU15 {
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint f, IntPtr e);
  [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
  public static bool Front(IntPtr h) {
    if (GetForegroundWindow() == h) return true;
    if (IsIconic(h)) ShowWindow(h, 9);
    keybd_event(0x12, 0, 0, IntPtr.Zero); keybd_event(0x12, 0, 2, IntPtr.Zero);
    SetForegroundWindow(h); System.Threading.Thread.Sleep(250);
    return GetForegroundWindow() == h;
  }
  public static void RightClick(int x, int y) { SetCursorPos(x - 30, y - 20); System.Threading.Thread.Sleep(120); SetCursorPos(x, y); System.Threading.Thread.Sleep(150); mouse_event(8, 0, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(40); mouse_event(16, 0, 0, 0, IntPtr.Zero); }
  // The viewer (SDL) reads scan codes.
  public static void Key(byte vk) { byte s = (byte)MapVirtualKey(vk, 0); keybd_event(vk, s, 0, IntPtr.Zero); System.Threading.Thread.Sleep(40); keybd_event(vk, s, 2, IntPtr.Zero); }
  // BGRA bytes: share of pixels that differ.
  public static double Diff(byte[] a, byte[] b) {
    int moved = 0, n = 0;
    for (int i = 0; i + 3 < a.Length && i + 3 < b.Length; i += 8) { if (Math.Abs(a[i] - b[i]) + Math.Abs(a[i+1] - b[i+1]) + Math.Abs(a[i+2] - b[i+2]) > 30) moved++; n++; }
    return n == 0 ? 0 : (double)moved / n;
  }
  // BGRA bytes: mean hue (degrees) of the colored pixels and their share.
  public static double[] Hue(byte[] p) {
    double sx = 0, sy = 0; int c = 0, n = 0;
    for (int i = 0; i + 3 < p.Length; i += 4) {
      int b = p[i], g = p[i+1], r = p[i+2]; int mx = Math.Max(r, Math.Max(g, b)), mn = Math.Min(r, Math.Min(g, b)); n++;
      if (mx - mn < 40) continue;
      double d = mx - mn, h = mx == r ? (g - b) / d : mx == g ? 2 + (b - r) / d : 4 + (r - g) / d;
      h *= Math.PI / 3; sx += Math.Cos(h); sy += Math.Sin(h); c++;
    }
    double deg = c == 0 ? -1 : (Math.Atan2(sy, sx) * 180 / Math.PI + 360) % 360;
    return new[] { deg, n == 0 ? 0 : (double)c / n };
  }
}
'@
}

$script:MuDesc = [Windows.Automation.TreeScope]::Descendants
$script:MuOn = '^(On|Encendida)$'
$script:MuOff = '^(Off|Apagada)$'

function Show-MuMain { $app = Get-App; if ($app) { [MU15]::Front($app.MainWindowHandle) } else { $false } }

function Find-MuClass($Root, [string]$Class) {
    if (-not $Root) { return $null }
    try { $Root.FindFirst($script:MuDesc, [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ClassNameProperty, $Class)) } catch { $null }
}

function Find-MuTyped($Root, $Type, [string]$Pattern = '.') {
    if (-not $Root) { return @() }
    $cond = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, $Type)
    try { @($Root.FindAll($script:MuDesc, $cond) | Where-Object { $_.Current.Name -match $Pattern }) } catch { @() }
}

function Show-MuElement($Element) {
    $p = $null
    try { if ($Element.TryGetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern, [ref]$p)) { $p.ScrollIntoView(); Start-Sleep -Milliseconds 350 } } catch { }
    # Pages scroll smoothly (a tab scrolls to its section too): wait until the element stops moving.
    $last = $null; $same = 0
    for ($i = 0; $i -lt 20 -and $same -lt 3; $i++) {
        Start-Sleep -Milliseconds 250
        try { $now = "$($Element.Current.BoundingRectangle)" } catch { return }
        if ($now -eq $last) { $same++ } else { $same = 0 }
        $last = $now
    }
}

function Press($Element, [string]$Process = 'gpuvm') {
    if (-not $Element) { return $false }
    Show-MuElement $Element
    Click-Element $Element $Process
}

function Get-MuSide([string]$Pattern) {
    Find-MuTyped (Get-MainElement) ([Windows.Automation.ControlType]::Button) $Pattern | Where-Object { $_.Current.ClassName -match '\bside-item\b' } | Select-Object -First 1
}

function Get-MuRows {
    @(Find-MuTyped (Get-MainElement) ([Windows.Automation.ControlType]::Button) | Where-Object {
        $c = $_.Current
        $c.Name -and $c.ClassName -match '\bside-item\b' -and $c.ClassName -notmatch 'side-home|side-add|side-skeleton|side-label|side-space' -and $c.HelpText -notmatch 'View progress|Ver avance'
    })
}

function Get-MuRow([string]$Vm) { Get-MuRows | Where-Object { $_.Current.Name -match "^$([regex]::Escape($Vm))(\s|,|$)" } | Select-Object -First 1 }

function Find-MuHeading([string]$Text) {
    $root = Get-MainElement
    if (-not $root) { return $null }
    $cond = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, $Text)
    try { @($root.FindAll($script:MuDesc, $cond) | Where-Object { $_.Current.ControlType -ne [Windows.Automation.ControlType]::Button -and $_.Current.ClassName -notmatch 'side-item|titlebar|\bname\b' }) | Select-Object -First 1 } catch { $null }
}

# The one button matching $Pattern in the closest box that also says $Text.
function Find-MuNear([string]$Pattern, [string]$Text) {
    $root = Get-MainElement
    if (-not $root) { return $null }
    $walker = [Windows.Automation.TreeWalker]::RawViewWalker
    foreach ($b in Find-MuTyped $root ([Windows.Automation.ControlType]::Button) $Pattern) {
        $up = $b
        for ($i = 0; $i -lt 10; $i++) {
            $up = $walker.GetParent($up)
            if (-not $up) { break }
            if ((Get-Texts $up) -match [regex]::Escape($Text)) {
                if (@(Find-MuTyped $up ([Windows.Automation.ControlType]::Button) $Pattern).Count -eq 1) { return $b }
                break
            }
        }
    }
    # Cards whose box UI Automation doesn't expose (Library templates): the button below and right of the name.
    $buttons = @(Find-MuTyped $root ([Windows.Automation.ControlType]::Button) $Pattern)
    $best = $null; $dist = [double]::MaxValue
    foreach ($t in (Find-MuTyped $root ([Windows.Automation.ControlType]::Text) "^$([regex]::Escape($Text))$")) {
        $tr = $t.Current.BoundingRectangle
        foreach ($b in $buttons) {
            $br = $b.Current.BoundingRectangle
            $dx = $br.X - $tr.X; $dy = $br.Y - $tr.Y
            if ($dx -ge -10 -and $dx -lt 300 -and $dy -gt 0 -and $dy -lt 250 -and $dx + $dy -lt $dist) { $best = $b; $dist = $dx + $dy }
        }
    }
    $best
}

function Find-MuDialog([string]$Pattern) {
    $root = Get-MainElement
    if (-not $root) { return $null }
    try { @($root.FindAll($script:MuDesc, [Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.ClassName -match '(^|\s)dialog(\s|$)' -and $_.Current.Name -match $Pattern }) | Select-Object -First 1 } catch { $null }
}

# The state-pill span has no box in UI Automation: its text is the plain text under the name, left of the header's
# More options button and outside the spec chips.
function Get-MuPill {
    $root = Get-MainElement
    $p = Find-MuClass $root 'state-pill'
    if ($p) { $n = $p.Current.Name; if (-not $n) { $n = Get-Texts $p }; return $n.Trim() }
    $more = Find-MuTyped $root ([Windows.Automation.ControlType]::Button) '^(More options|Más opciones)$' | Select-Object -First 1
    if (-not $more) { return '' }
    $m = $more.Current.BoundingRectangle
    $walker = [Windows.Automation.TreeWalker]::RawViewWalker
    $t = Find-MuTyped $root ([Windows.Automation.ControlType]::Text) | Where-Object {
        $r = $_.Current.BoundingRectangle; $cy = $r.Y + $r.Height / 2
        $r.Height -le 20 -and $r.X -lt $m.X -and $cy -ge $m.Y -and $cy -le $m.Y + $m.Height + 15 -and $walker.GetParent($_).Current.ClassName -notmatch 'spec-chip'
    } | Sort-Object { $_.Current.BoundingRectangle.X } | Select-Object -First 1
    if ($t) { $t.Current.Name.Trim() } else { '' }
}

function Wait-MuPill([string]$Pattern, [double]$Seconds) {
    $r = Wait-For { $t = Get-MuPill; if ($t -match $Pattern -and -not (Get-MuBusy)) { $t } } $Seconds
    if ($r) { $r } else { Get-MuPill }
}

function Get-MuBusy { $b = Find-MuClass (Get-MainElement) 'primary busy'; if ($b) { "$($b.Current.Name) $($b.Current.HelpText)".Trim() } }

function Get-MuSteps {
    $root = Get-MainElement
    @((Get-MuBusy), $(if ($s = Find-MuClass $root 'viewer-stage-steps') { Get-Texts $s })) | Where-Object { $_ }
}

function Find-MuMenuItem([string]$Pattern) { Find-MuTyped (Get-MainElement) ([Windows.Automation.ControlType]::MenuItem) $Pattern | Select-Object -First 1 }

function Invoke-MuMenu([string]$Pattern) {
    $item = Find-MuMenuItem $Pattern
    if (-not $item) {
        $null = Show-MuMain
        $more = Find-MuTyped (Get-MainElement) ([Windows.Automation.ControlType]::Button) '^(More options|Más opciones)$' | Select-Object -First 1
        $null = Press $more
        $item = Wait-For { Find-MuMenuItem $Pattern } 3
    }
    if (-not $item) { Write-Host "     menu item not found: $Pattern"; return $false }
    Press $item
}

function Open-MuPage([string]$Vm) {
    $null = Show-MuMain
    $back = Find-MuClass (Get-MainElement) 'titlebar-back'
    if ($back) {
        $back = Wait-For { $e = Find-MuClass (Get-MainElement) 'titlebar-back'; if ($e -and $e.Current.IsEnabled) { $e } } 10
        if (-not (Click-Element $back)) { $null = Invoke-Element $back }
        $null = Wait-For { -not (Find-MuClass (Get-MainElement) 'titlebar-back') } 8
        $null = Show-MuMain
    }
    $row = Wait-For { Get-MuRow $Vm } 10
    if (-not (Press $row)) { $null = Invoke-Element $row }
    [bool](Wait-For { $r = Get-MuRow $Vm; $r -and $r.Current.ClassName -match '\bactive\b' -and (Find-MuHeading $Vm) -and (Find-Named (Get-MainElement) '^(Uptime|Tiempo encendida)$') } 8)
}

function Get-MuViewer {
    $p = Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { return $null }
    $best = $null
    foreach ($h in [E2E]::WindowsOf([uint32]$p.Id)) {
        $r = [E2E]::Rect($h)
        if ($r[2] -lt 200 -or $r[3] -lt 150) { continue }
        if (-not $best -or $r[2] * $r[3] -gt $best.W * $best.H) { $best = [pscustomobject]@{ X = $r[0]; Y = $r[1]; W = $r[2]; H = $r[3] } }
    }
    $best
}

function Test-MuPicture { $s = Screen; [E2E]::ProcessNameAt($s.X + [int]($s.Width / 2), $s.Y + [int]($s.Height / 2)) -eq 'GpuVMViewer' }

function Get-MuPictureBytes {
    $v = Get-MuViewer
    if (-not $v) { return , [byte[]]@() }
    $bmp = Grab ($v.X + [int]($v.W * 0.1)) ($v.Y + [int]($v.H * 0.15)) ([int]($v.W * 0.8)) ([int]($v.H * 0.7))
    $b = Bytes $bmp; $bmp.Dispose(); , $b
}

function Get-MuArea($Element) {
    $r = $Element.Current.BoundingRectangle
    $bmp = Grab ([int]$r.X + 3) ([int]$r.Y + 3) ([Math]::Max(1, [int]$r.Width - 6)) ([Math]::Max(1, [int]$r.Height - 6))
    $b = Bytes $bmp; $bmp.Dispose(); , $b
}

# Back to the app from the picture with the title bar's Home; a picture that fills the monitor covers the title bar,
# and there the person's way is Ctrl+Alt+Shift+H.
function Exit-MuPicture([string]$Name) {
    $back = Wait-For { $e = Find-MuClass (Get-MainElement) 'titlebar-back'; if ($e -and $e.Current.IsEnabled) { $e } } 10
    $v = Get-MuViewer; $s = Screen
    $full = $v -and $v.X -le $s.X -and $v.Y -le $s.Y -and $v.X + $v.W -ge $s.X + $s.Width -and $v.Y + $v.H -ge $s.Y + $s.Height
    $how = 'title bar Home'
    if ($back -and $full) {
        $how = 'Ctrl+Alt+Shift+H (the picture fills the monitor)'
        $null = [MU15]::Front((Get-Process GpuVMViewer | Select-Object -First 1).MainWindowHandle)
        Start-Sleep -Milliseconds 300
        [E2E]::Combo([byte][char]'H')
        $done = $true
    }
    else { $done = Click-Element $back }
    $left = Wait-For { -not (Test-MuPicture) -and -not (Find-MuClass (Get-MainElement) 'titlebar-back') } 8
    Check "${Name}: going Home hides the picture and shows the app" ([bool]$back -and $done -and $left) $(if (-not $back) { 'no enabled Home in the title bar' } elseif (-not $done) { "$how not clickable" } else { $how })
    Start-Sleep -Milliseconds 600
}

# The picture of a machine back in front from Home's Open (or Start and open) for it.
function Show-MuPicture([string]$Vm) {
    $null = Show-MuMain
    $null = Press (Get-MuSide '^(Home|Inicio)$')
    $open = Wait-For { Find-MuNear '^(Open|Abrir|Start and open|Encender y abrir|Start|Encender)$' $Vm } 8
    if (-not (Press $open)) { return $false }
    $shown = [bool](Wait-For { Test-MuPicture } 30)
    if ($shown) { Start-Sleep -Milliseconds 1500 }
    $shown
}

function Invoke-MuTool($S, [string]$Name, [hashtable]$Arguments, [double]$Seconds = 90) {
    if ($S.PSObject.Properties.Name -notcontains 'Pending') { $S | Add-Member -NotePropertyName Pending -NotePropertyValue $null }
    $id = Start-Tool $S $Name $Arguments
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ($true) {
        if (-not $S.Pending) { $S.Pending = $S.Process.StandardOutput.ReadLineAsync() }
        $left = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
        if (-not $S.Pending.Wait($left)) { return $null }
        $line = $S.Pending.Result; $S.Pending = $null
        if ($null -eq $line) { throw 'The MCP server closed.' }
        $r = $line | ConvertFrom-Json
        if ($r.id -eq $id) { return $r }
    }
}

function Get-MuText($Reply) { if ($null -eq $Reply) { '(no answer in time)' } elseif ($Reply.error) { "JSON-RPC error: $($Reply.error.message)" } else { Text-Of $Reply } }

function Test-MuOk($Reply) { [bool]($Reply -and -not $Reply.error -and -not $Reply.result.isError) }

# A guest file call, retried while the machine's Windows is still starting.
function Invoke-MuGuest($S, [string]$Name, [hashtable]$Arguments, [double]$Seconds = 240) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $r = Invoke-MuTool $S $Name $Arguments 60
        if ((Test-MuOk $r) -or (Get-MuText $r) -match 'not found|no such|cannot find|does not exist|no existe') { return $r }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    $r
}

function Rename-MuMachine([string]$From, [string]$To) {
    if (-not (Invoke-MuMenu '^(Rename|Cambiar nombre)$')) { return $false }
    $dialog = Wait-For { Find-MuDialog "^(Rename|Cambiar el nombre de) $([regex]::Escape($From))$" } 4
    $box = if ($dialog) { Find-MuTyped $dialog ([Windows.Automation.ControlType]::Edit) | Select-Object -First 1 }
    if (-not (Press $box)) { return $false }
    [Windows.Forms.SendKeys]::SendWait('^a')
    [Windows.Forms.SendKeys]::SendWait($To)
    $ok = Wait-For { $b = Find-MuTyped $dialog ([Windows.Automation.ControlType]::Button) '^(Rename|Cambiar nombre)$' | Select-Object -First 1; if ($b -and $b.Current.IsEnabled) { $b } } 3
    if (-not (Press $ok)) { return $false }
    [bool](Wait-For { (Get-MuRow $To) -and (Find-MuHeading $To) -and -not (Get-MuRow $From) -and -not (Get-MuBusy) } 120)
}

function Start-MuMachine {
    if ((Get-MuPill) -match $script:MuOff) { $null = Invoke-MuMenu '^(Start without opening|Encender sin abrir)$' }
    Wait-MuPill $script:MuOn 180
}

function Get-MuIconHue {
    $icon = Find-MuClass (Get-MainElement) 'pattern-btn'
    if (-not $icon) { return -1 }
    Show-MuElement $icon
    Start-Sleep -Milliseconds 500
    ([MU15]::Hue((Get-MuArea $icon)))[0]
}

function Test-UiDisposable($Ctx) {
    $base = "$($Ctx.Template.Substring(0, [Math]::Min(29, $Ctx.Template.Length)))-desechable"
    $known = @(Get-MuRows | ForEach-Object { $_.Current.Name })
    $null = Show-MuMain
    $null = Press (Get-MuSide '^(Library|Biblioteca)$')
    $tab = Wait-For { Find-MuTyped (Get-MainElement) ([Windows.Automation.ControlType]::TabItem) '^(Templates|Plantillas)$' | Select-Object -First 1 } 6
    $null = Press $tab
    $open = Wait-For { Find-MuNear '^(Open disposable|Abrir desechable)$' $Ctx.Template } 8
    Check "Library Templates shows Open disposable for $($Ctx.Template)" ([bool]$open) ''
    if (-not (Press $open)) { return $null }

    $vm = $null; $steps = [Collections.Generic.List[string]]::new(); $seen = $false
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 300) {
        foreach ($s in Get-MuSteps) { if (-not $steps.Contains($s)) { $steps.Add($s) } }
        if (-not $vm) {
            $row = Get-MuRows | Where-Object { $_.Current.Name -match "^$([regex]::Escape($base))(-\d+)?(\s|,|$)" -and $known -notcontains $_.Current.Name } | Select-Object -First 1
            if ($row) { $vm = ($row.Current.Name -split '[\s,]')[0]; $seen = $true; $null = Press $row }
        }
        if (Test-MuPicture) { break }
        Start-Sleep -Milliseconds 250
    }
    $front = Test-MuPicture
    Shot 'machine-ui-1-disposable-open'
    Check 'Open disposable: the header shows its steps' ($steps.Count -gt 0) ($steps -join ' / ')
    Check 'Open disposable: the picture comes in front (GpuVMViewer at the screen''s center)' $front ("{0:N0} s" -f $sw.Elapsed.TotalSeconds)
    if ($front) { Exit-MuPicture 'the new disposable' }
    if (-not $vm) {
        $row = Get-MuRows | Where-Object { $_.Current.Name -match "^$([regex]::Escape($base))(-\d+)?(\s|,|$)" -and $known -notcontains $_.Current.Name } | Select-Object -First 1
        if ($row) { $vm = ($row.Current.Name -split '[\s,]')[0] }
    }
    Check 'Open disposable: a new sidebar row appears' ([bool]$vm) $(if ($vm) { "$vm$(if (-not $seen) { ' (seen after going Home)' })" } else { '' })
    $vm
}

function Test-PowerMenu([string]$Vm) {
    if (-not (Open-MuPage $Vm)) { Check "${Vm}: its machine page opens" $false ''; return }
    $null = Invoke-MuMenu '^(Pause|Pausar)$'
    $pill = Wait-MuPill '^(Paused|En pausa)$' 30
    Check 'Pause: the state shows Paused' ($pill -match '^(Paused|En pausa)$') "state: $pill"
    if (Show-MuPicture $Vm) {
        $a = Get-MuPictureBytes; Start-Sleep -Seconds 2; $b = Get-MuPictureBytes
        $d = [MU15]::Diff($a, $b)
        Check 'paused: two captures of the picture 2 s apart are identical' ($a.Length -gt 0 -and $d -lt 0.001) ("{0:P2} of pixels differ" -f $d)
        Shot 'machine-ui-2-paused'
        Exit-MuPicture 'paused'
    } else { Check 'paused: the picture comes back in front from Home' $false '' }

    $null = Open-MuPage $Vm
    $null = Invoke-MuMenu '^(Resume|Reanudar)$'
    $pill = Wait-MuPill $script:MuOn 30
    Check 'Resume: the state shows On' ($pill -match $script:MuOn) "state: $pill"
    if (Show-MuPicture $Vm) {
        $a = Get-MuPictureBytes
        $v = Get-MuViewer
        $x = $v.X + [int]($v.W / 2); $y = $v.Y + [int]($v.H / 2)
        if ([E2E]::ProcessNameAt($x, $y) -eq 'GpuVMViewer') { [MU15]::RightClick($x, $y) }
        Start-Sleep -Seconds 2
        $b = Get-MuPictureBytes
        $d = [MU15]::Diff($a, $b)
        Check 'resumed: the picture changes (a right click opens a menu)' ($a.Length -gt 0 -and $d -ge 0.002) ("{0:P2} of pixels differ" -f $d)
        Shot 'machine-ui-3-resumed'
        [MU15]::Key(0x1B)
        Start-Sleep -Milliseconds 400
        Exit-MuPicture 'resumed'
    } else { Check 'resumed: the picture comes back in front from Home' $false '' }

    $null = Open-MuPage $Vm
    $restarting = $null
    if (Invoke-MuMenu '^(Restart|Reiniciar)$') {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not $restarting -and $sw.Elapsed.TotalSeconds -lt 20) {
            $t = "$(Get-MuBusy) $((Get-MuRow $Vm).Current.HelpText)"
            if ($t -match 'Restarting|Reiniciando') { $restarting = $t.Trim() }
            Start-Sleep -Milliseconds 80
        }
    }
    Check 'Restart: the header shows Restarting…' ([bool]$restarting) $restarting
    $pill = Wait-MuPill $script:MuOn 120
    Check 'Restart: the state comes back to On' ($pill -match $script:MuOn) "state: $pill"

    $null = Invoke-MuMenu '^(Force shutdown|Forzar apagado)$'
    $warn = Wait-For { Find-MuMenuItem '^(Force: unsaved work is lost|Forzar: se pierde lo no guardado)$' } 3
    Check 'Force shutdown: the first click shows the two-step warning' ([bool]$warn) ''
    Shot 'machine-ui-4-force-warning'
    Start-Sleep -Seconds 2
    $pill = Get-MuPill
    Check 'Force shutdown: the first click does not shut it down' ($pill -match $script:MuOn) "state: $pill"
    $pressed = Press $warn
    $gone = $pressed -and (Wait-For { (Get-MuSide '^(Home|Inicio)$') -and -not (Get-MuRow $Vm) } 90)
    Check 'Force shutdown confirmed: it shuts down and the disposable''s row disappears within 90 s' ([bool]$gone) $(if (-not $pressed) { 'the warning item was not clicked' } else { '' })
}

function Test-KeptMachine($Ctx, $St) {
    $S = $Ctx.Mcp
    $vm = $St.Name
    $r = Invoke-MuTool $S 'create_disposable' @{ template = $Ctx.Template; name = $vm; cpu = 3; memoryGB = 5; task = 'End-to-end machine UI' } 600
    $St.Created = (Test-MuOk $r) -and (Get-MuText $r) -match [regex]::Escape($vm)
    Check 'agent create_disposable with cpu 3 and memoryGB 5' $St.Created (Get-MuText $r)
    if (-not $St.Created) { return }
    $page = Open-MuPage $vm
    $texts = if ($page) { Get-Texts (Get-MainElement) } else { '' }
    Check "${vm}: the machine page shows 3 threads" ($texts -match '(^|\| )(3 threads|3 hilos)( \||$)') ''
    Check "${vm}: the machine page shows 5 GB" ($texts -match '(^|\| )5 GB( \||$)') ''
    Shot 'machine-ui-5-agent-disposable'

    $null = Invoke-MuGuest $S 'write_file' @{ machine = $vm; path = 'Desktop\before.txt'; content = 'before' }
    $keep = Wait-For { Find-MuTyped (Get-MainElement) ([Windows.Automation.ControlType]::Button) '^(Keep|Conservar)$' | Select-Object -First 1 } 6
    $null = Show-MuMain
    $null = Press $keep
    $create = Wait-For { Find-MuTyped (Get-MainElement) ([Windows.Automation.ControlType]::Button) '^(Create point|Crear punto|Shut down and create point|Apagar y crear punto)$' | Select-Object -First 1 } 20
    $St.Kept = [bool]$create
    Check 'Keep makes it a regular machine (its restore points show)' $St.Kept ''
    if (-not $St.Kept) { return }

    $points = { @(Find-MuTyped (Get-MainElement) ([Windows.Automation.ControlType]::Button) '^(Go back|Volver)$').Count }
    $n0 = & $points
    $null = Press $create
    $made = Wait-For { (& $points) -eq $n0 + 1 -and -not (Get-MuBusy) } 480
    Check 'Create point: a new restore point row appears' ([bool]$made) "$n0 point(s) before, $(& $points) now"

    $pill = Start-MuMachine
    $w = Invoke-MuGuest $S 'write_file' @{ machine = $vm; path = 'Desktop\after.txt'; content = 'after' }
    Check 'the agent writes Desktop\after.txt after the point' (Test-MuOk $w) "state: $pill; $(Get-MuText $w)"

    $n1 = & $points
    $go = Find-MuTyped (Get-MainElement) ([Windows.Automation.ControlType]::Button) '^(Go back|Volver)$' | Select-Object -First 1
    $null = Show-MuMain
    $null = Press $go
    $dialog = Wait-For { Find-MuDialog '^(Go back to|Volver a) ' } 4
    $save = if ($dialog) { Find-MuTyped $dialog ([Windows.Automation.ControlType]::CheckBox) 'Save how it is now|Guardar cómo está ahora' | Select-Object -First 1 }
    $p = $null; $on = $false
    if ($save -and $save.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern, [ref]$p)) {
        if ($p.Current.ToggleState -ne 'On') { $null = Press $save; Start-Sleep -Milliseconds 300 }
        $on = $p.Current.ToggleState -eq 'On'
    }
    Check 'Go back: "Save how it is now" is checked' $on ''
    Shot 'machine-ui-6-go-back'
    $confirm = if ($dialog) { Find-MuTyped $dialog ([Windows.Automation.ControlType]::Button) '^(Go back|Volver)$' | Select-Object -First 1 }
    if ($on) { $null = Press $confirm } else { $null = Press (Find-MuTyped $dialog ([Windows.Automation.ControlType]::Button) '^(Cancel|Cancelar)$' | Select-Object -First 1); return }
    $back = Wait-For { -not (Get-MuBusy) -and (& $points) -eq $n1 + 1 } 480
    Check 'Go back with "Save how it is now": a point of the present is added' ([bool]$back) "$n1 point(s) before, $(& $points) now; state: $(Get-MuPill)"

    $null = Start-MuMachine
    $before = Invoke-MuGuest $S 'read_file' @{ machine = $vm; path = 'Desktop\before.txt' }
    $after = Invoke-MuTool $S 'read_file' @{ machine = $vm; path = 'Desktop\after.txt' } 60
    Check 'after going back: Desktop\after.txt is gone (read_file fails) and before.txt is there' ((Test-MuOk $before) -and (Get-MuText $before) -match 'before' -and -not (Test-MuOk $after)) "after: $(Get-MuText $after) / before: $(Get-MuText $before)"

    $null = Invoke-MuTool $S 'release_machine' @{ machine = $vm } 30
    $null = Invoke-MuMenu '^(Shut down|Apagar)$'
    $pill = Wait-MuPill $script:MuOff 240
    Check 'Shut down from the menu turns it off' ($pill -match $script:MuOff) "state: $pill"

    $other = "$vm-r"
    $renamed = Rename-MuMachine $vm $other
    Check "Rename while off: $other shows in the sidebar and the header" $renamed ''
    Shot 'machine-ui-7-renamed'
    if ($renamed) {
        $St.Name = $other
        $back = Rename-MuMachine $other $vm
        if ($back) { $St.Name = $vm } else { Shot 'machine-ui-rename-back-failed' }
        Check "Rename back: $vm shows again in the sidebar and the header" $back ''
    }

    $null = Show-MuMain
    $null = Press (Find-MuTyped (Get-MainElement) ([Windows.Automation.ControlType]::TabItem) '^(Customize|Personalizar)$' | Select-Object -First 1)
    Start-Sleep -Milliseconds 800
    $icon = Find-MuClass (Get-MainElement) 'pattern-btn'
    if ($icon) {
        Show-MuElement $icon; Start-Sleep -Milliseconds 400
        $a = Get-MuArea $icon
        $null = Press $icon
        Start-Sleep -Milliseconds 800
        $d = [MU15]::Diff($a, (Get-MuArea (Find-MuClass (Get-MainElement) 'pattern-btn')))
        Check 'Customize: Another icon changes the icon''s pixels' ($d -ge 0.05) ("{0:P1} of pixels differ" -f $d)
    } else { Check 'Customize: Another icon changes the icon''s pixels' $false 'icon button not found' }

    $group = { Find-Named (Get-MainElement) '^(Machine color|Color de la máquina)$' }
    $radios = @(Find-MuTyped (& $group) ([Windows.Automation.ControlType]::RadioButton))
    $isOn = { param($e) $q = $null; $e.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$q) -and $q.Current.IsSelected }
    $orig = $radios | Where-Object { & $isOn $_ } | Select-Object -First 1
    $h0 = Get-MuIconHue; $h1 = $h0; $tried = @()
    foreach ($c in @($radios | Where-Object { $_.Current.Name -ne $orig.Current.Name } | Select-Object -Skip 2 -First 3)) {
        $tried += $c.Current.Name
        $null = Show-MuMain
        $null = Press $c
        Start-Sleep -Milliseconds 600
        $h1 = Get-MuIconHue
        $dh = [Math]::Abs($h1 - $h0); $dh = [Math]::Min($dh, 360 - $dh)
        if ($h0 -ge 0 -and $h1 -ge 0 -and $dh -ge 12) { break }
    }
    $dh = [Math]::Abs($h1 - $h0); $dh = [Math]::Min($dh, 360 - $dh)
    Check 'Customize: a different color swatch changes the icon''s hue' ($radios.Count -gt 3 -and $h0 -ge 0 -and $h1 -ge 0 -and $dh -ge 12) ("hue {0:N0} -> {1:N0} with {2}" -f $h0, $h1, ($tried -join ', '))
    Shot 'machine-ui-8-customized'
    if ($orig) {
        $name = $orig.Current.Name
        $again = Find-MuTyped (& $group) ([Windows.Automation.ControlType]::RadioButton) "^$([regex]::Escape($name))$" | Select-Object -First 1
        $null = Show-MuMain
        $null = Press $again
        Start-Sleep -Milliseconds 500
        $now = Find-MuTyped (& $group) ([Windows.Automation.ControlType]::RadioButton) "^$([regex]::Escape($name))$" | Select-Object -First 1
        Check "the machine's color goes back to $name" ($now -and (& $isOn $now)) ''
    }
}

function Test-Suite($Ctx) {
    $null = Show-MuMain
    if (-not (Wait-For { Get-MuSide '^(Home|Inicio)$' } 10)) { Check 'machine UI: the main window shows the sidebar' $false ''; return }
    $S = $Ctx.Mcp
    if ($S.PSObject.Properties.Name -contains 'Pending' -and $S.Pending) { $null = $S.Pending.Wait(30000); $S.Pending = $null }
    $ui = $null
    $St = [pscustomobject]@{ Name = "e2e-$('{0:x6}' -f (Get-Random -Maximum 0xFFFFFF))"; Created = $false; Kept = $false }
    try {
        $ui = Test-UiDisposable $Ctx
        if ($ui) { Test-PowerMenu $ui }
        Test-KeptMachine $Ctx $St
    }
    finally {
        try { if (Test-MuPicture) { Exit-MuPicture 'cleanup' } } catch { }
        try {
            if ($ui -and (Get-MuRow $ui) -and (Open-MuPage $ui) -and (Get-MuPill) -notmatch $script:MuOff) {
                $null = Invoke-MuMenu '^(Force shutdown|Forzar apagado)$'
                $null = Invoke-MuMenu '^(Force: unsaved work is lost|Forzar: se pierde lo no guardado)$'
            }
        } catch { }
        # When its page couldn't be used, the disposable still goes: left on, it takes memory from the next suites.
        if ($ui -and (Get-VM -Name $ui -ErrorAction SilentlyContinue)) {
            try { Stop-VM -Name $ui -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVMDisposable -Name $ui -Confirm:$false -ErrorAction SilentlyContinue 6>$null | Out-Null } catch { }
        }
        if ($St.Created -and -not $St.Kept) {
            try { $null = Invoke-MuTool $S 'destroy' @{ machine = $St.Name; force = $true } 180 } catch { }
        } elseif ($St.Kept) {
            try { $null = Invoke-MuTool $S 'release_machine' @{ machine = $St.Name } 30 } catch { }
            try {
                if ((Open-MuPage $St.Name) -and (Get-MuPill) -notmatch $script:MuOff) {
                    $null = Invoke-MuMenu '^(Shut down|Apagar)$'
                    $null = Wait-MuPill $script:MuOff 240
                }
            } catch { }
            $pill = Get-MuPill
            Check "the kept machine $($St.Name) is left off" ($pill -match $script:MuOff) "state: $pill"
            Write-Host "INFO  kept machine $($St.Name) (off): it can only be deleted with a UAC consent."
            Check "kept machine $($St.Name): the operator must delete it from GpuVM" $true ''
        }
        try { $null = Show-MuMain; $null = Press (Get-MuSide '^(Home|Inicio)$') } catch { }
    }
}
