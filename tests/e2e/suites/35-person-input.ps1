# What the person's mouse and keyboard do while an agent holds the machine: hovering, typing, taking control (by
# input or by the button), handing back, the administrator dock, dropping a file, and the Clipboard and Capture widgets.
if (-not ('PI35' -as [type])) {
    Add-Type @'
using System; using System.Runtime.InteropServices;
public static class PI35 {
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] static extern void mouse_event(uint f, int x, int y, uint d, IntPtr e);
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint f, IntPtr e);
  [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern short VkKeyScan(char c);
  [DllImport("user32.dll")] static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
  // A zero relative move after SetCursorPos: an input event that a drag-and-drop loop sees.
  public static void To(int x, int y) { SetCursorPos(x, y); mouse_event(1, 0, 0, 0, IntPtr.Zero); }
  public static void Down() { mouse_event(2, 0, 0, 0, IntPtr.Zero); }
  public static void Up() { mouse_event(4, 0, 0, 0, IntPtr.Zero); }
  static void Key(byte vk, bool up) { keybd_event(vk, (byte)MapVirtualKey(vk, 0), up ? 2u : 0u, IntPtr.Zero); System.Threading.Thread.Sleep(35); }
  public static void Type(string s) {
    foreach (char c in s) { short v = VkKeyScan(c); byte vk = (byte)(v & 0xFF); bool shift = ((v >> 8) & 1) != 0;
      if (shift) Key(0x10, false); Key(vk, false); Key(vk, true); if (shift) Key(0x10, true); }
  }
  public static void Place(IntPtr h, int x, int y, int w, int hh) { MoveWindow(h, x, y, w, hh, true); }
}
'@
}

$script:PiBack = '^\W*(Return to agent|Volver al agente)\W*$'
$script:PiControl = 'took control|tomaste el control|have control|Tienes el control'

function Get-PiViewer {
    $p = Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { return $null }
    $best = $null
    foreach ($h in [E2E]::WindowsOf([uint32]$p.Id)) {
        $r = [E2E]::Rect($h)
        if ($r[2] -lt 200 -or $r[3] -lt 150) { continue }
        if (-not $best -or $r[2] * $r[3] -gt $best.W * $best.H) { $best = [pscustomobject]@{ Handle = $h; X = $r[0]; Y = $r[1]; W = $r[2]; H = $r[3] } }
    }
    $best
}

function Get-PiPoint([double]$FX, [double]$FY) {
    $v = Get-PiViewer
    if ($v) { [pscustomobject]@{ X = $v.X + [int]($v.W * $FX); Y = $v.Y + [int]($v.H * $FY) } }
}

function Click-PiPicture([double]$FX, [double]$FY) {
    $p = Get-PiPoint $FX $FY
    if (-not $p) { return $false }
    $at = [E2E]::ProcessNameAt($p.X, $p.Y)
    if ($at -ne 'GpuVMViewer') { Write-Host "     click refused: $at is over the picture at $($p.X),$($p.Y)"; return $false }
    [E2E]::Click($p.X, $p.Y)
    $true
}

function Test-PiPaused($Ctx, [string]$Vm) { (Invoke-Tool $Ctx.Mcp 'list_machines') -match "$([regex]::Escape($Vm))[^\n]*paused" }

function Find-PiAppButton([string]$Pattern) {
    $app = Get-App
    if (-not $app) { return $null }
    foreach ($w in Get-AppWindows) {
        if ($w.Handle -eq $app.MainWindowHandle) { continue }
        try {
            $b = Find-Named (Get-Element $w.Handle) $Pattern ([Windows.Automation.ControlType]::Button)
            if ($b -and $b.Current.IsEnabled -and $b.Current.BoundingRectangle.Width -gt 0) { return $b }
        } catch { }
    }
    $null
}

function Find-PiNotchButton([string]$Pattern) {
    foreach ($w in Get-AppWindows -Small) {
        $root = Get-Element $w.Handle
        if (-not $root) { continue }
        $bar = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::StatusBar))
        if (-not $bar -or $bar.Current.ClassName -notmatch '^sn\b') { continue }
        $b = Find-Named $bar $Pattern ([Windows.Automation.ControlType]::Button)
        if ($b -and $b.Current.IsEnabled) { return $b }
    }
    $null
}

# Gives the machine back to the agent if the person has it, and answers what wait_for_person says.
function Return-PiAgent($Ctx, [string]$Vm) {
    if (Test-PiPaused $Ctx $Vm) {
        $b = Wait-For { Find-PiAppButton $script:PiBack } 5
        if (-not ($b -and (Click-Element $b))) {
            if ([E2E]::Foreground() -notlike 'GpuVMViewer/*') { $null = Click-PiPicture 0.35 0.5; Start-Sleep -Milliseconds 400 }
            [E2E]::Combo([byte][char]'A')
        }
    }
    Invoke-Tool $Ctx.Mcp 'wait_for_person' @{ machine = $Vm; waitSeconds = 15 }
}

function Wait-PiWindow($Ctx, [string]$Vm, [string]$Pattern, [double]$Seconds = 25) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $t = Invoke-Tool $Ctx.Mcp 'ui_tree' @{ machine = $Vm; interactiveOnly = $false; maxNodes = 5 }
        if ($t -match $Pattern) { return $t }
        Start-Sleep -Milliseconds 700
    } while ((Get-Date) -lt $deadline)
    $t
}

function Get-PiExplorers {
    $cond = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ClassNameProperty, 'CabinetWClass')
    foreach ($e in [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $cond)) {
        [pscustomobject]@{ Handle = [int64]$e.Current.NativeWindowHandle; Name = $e.Current.Name; Element = $e }
    }
}

function Wait-PiNewExplorer($Before, [double]$Seconds = 12) {
    Wait-For { Get-PiExplorers | Where-Object { $Before -notcontains $_.Handle } | Select-Object -First 1 } $Seconds
}

function Close-PiExplorer($Window) {
    if (-not $Window) { return }
    try { $Window.Element.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close() } catch { }
}

function Show-PiElement($Element) {
    $p = $null
    try { if ($Element.TryGetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern, [ref]$p)) { $p.ScrollIntoView(); Start-Sleep -Milliseconds 300 } } catch { }
}

function Get-PiPanel {
    $app = Get-App
    if (-not $app) { return $null }
    foreach ($w in Get-AppWindows) {
        if ($w.Handle -eq $app.MainWindowHandle -or $w.W -lt 250 -or $w.H -lt 300) { continue }
        $root = Get-Element $w.Handle
        if (Find-Named $root '^(Viewer panel|Panel del visor)$') { return [pscustomobject]@{ Handle = $w.Handle; X = $w.X; Y = $w.Y; W = $w.W; H = $w.H; Root = $root } }
    }
    $null
}

function Get-PiWidget($Panel, [string]$Pattern) {
    if (-not $Panel) { return $null }
    foreach ($e in $Panel.Root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)) {
        $c = $e.Current
        if ($c.ClassName -match '\bvp-widget\b' -and $c.Name -match $Pattern) { return $e }
    }
    $null
}

function Test-PiSelected($Element) {
    $p = $null
    try {
        if ($Element.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { return $p.Current.IsSelected }
        if ($Element.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern, [ref]$p)) { return $p.Current.ToggleState -eq 'On' }
    } catch { }
    $false
}

function Get-PiSide([string]$Pattern) {
    $buttons = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button)
    $root = Get-MainElement
    if (-not $root) { return $null }
    @($root.FindAll([Windows.Automation.TreeScope]::Descendants, $buttons) | Where-Object { $_.Current.ClassName -match '\bside-item\b' -and $_.Current.Name -match $Pattern }) | Select-Object -First 1
}

# Settings > Agents > Take control: the two options of its switch.
function Get-PiTakeControl {
    $null = Invoke-Element (Get-PiSide '^(Settings|Ajustes)$')
    $nav = Wait-For { Find-Named (Get-MainElement) '^(Settings sections|Secciones de Ajustes)$' } 6
    if (-not $nav) { return $null }
    $tab = Find-Named $nav '^(Agents|Agentes)$' ([Windows.Automation.ControlType]::TabItem)
    if (-not $tab) { return $null }
    $null = Invoke-Element $tab
    Wait-For {
        $root = Get-MainElement
        $button = Find-Named $root '(Button only|Solo con el bot)' ([Windows.Automation.ControlType]::RadioButton)
        $byInput = Find-Named $root '(Click or key|Clic o tecla)' ([Windows.Automation.ControlType]::RadioButton)
        if ($button -and $byInput) { [pscustomobject]@{ Button = $button; Input = $byInput } }
    } 6
}

function Get-PiVideos([string]$Vm) {
    $dirs = @((Join-Path ([Environment]::GetFolderPath('MyVideos')) 'GpuVM'), $env:GPUVM_E2E_VIDEOS) | Where-Object { $_ }
    @(foreach ($d in $dirs) { Get-ChildItem -LiteralPath (Join-Path $d $Vm) -File -ErrorAction SilentlyContinue | ForEach-Object FullName })
}

function Find-PiDropZone {
    $app = Get-App
    foreach ($w in Get-AppWindows) {
        if ($app -and $w.Handle -eq $app.MainWindowHandle) { continue }
        try { if ((Get-Texts (Get-Element $w.Handle)) -match 'Drop to send|Soltar para enviar') { return $w } } catch { }
    }
    $null
}

function Test-PiHover($Ctx, [string]$Vm) {
    $intent = 'Hover check'
    $pending = Start-Tool $Ctx.Mcp 'run' @{ machine = $Vm; command = 'Start-Sleep -Seconds 8'; intent = $intent }
    $n = Wait-Notch $intent 6
    Check 'hover: the notch shows the agent''s intent before hovering' ($n -and $n.Text -match $intent) "text: $($n.Text)"
    $texts = [Collections.Generic.List[string]]::new()
    $spots = @(@(0.3, 0.5), @(0.62, 0.42), @(0.5, 0.72), @(0.72, 0.64), @(0.4, 0.32), @(0.55, 0.55))
    $from = Get-PiPoint 0.2 0.6
    foreach ($s in $spots) {
        $to = Get-PiPoint $s[0] $s[1]
        if (-not $from -or -not $to) { break }
        for ($i = 1; $i -le 10; $i++) { [E2E]::Move($from.X + ($to.X - $from.X) * $i / 10, $from.Y + ($to.Y - $from.Y) * $i / 10); Start-Sleep -Milliseconds 30 }
        $from = $to
        Start-Sleep -Milliseconds 250
        $x = Get-Notch
        if ($x) { $texts.Add($x.Text) }
    }
    $took = @($texts | Where-Object { $_ -match $script:PiControl })
    $kept = @($texts | Where-Object { $_ -match $intent })
    Check 'hovering the picture never takes control' ($texts.Count -and -not $took.Count) "$($texts.Count) samples; took control in $($took.Count)"
    Check 'hovering: the notch keeps the intent' ($texts.Count -and $kept.Count -eq $texts.Count) "$($kept.Count) of $($texts.Count) samples show it; last: $($texts | Select-Object -Last 1)"
    $reply = Text-Of (Receive-Mcp $Ctx.Mcp $pending)
    Check 'hovering: the agent''s command ran to the end' ($reply -notmatch 'took control') $reply
    Check 'hovering: list_machines doesn''t show the machine paused' (-not (Test-PiPaused $Ctx $Vm)) ''
}

function Test-PiTyping($Ctx, [string]$Vm, [string]$Tag) {
    $home_ = (Invoke-Tool $Ctx.Mcp 'run' @{ machine = $Vm; command = 'Write-Output $env:USERPROFILE' }) -replace '(?s).*?([A-Z]:\\[^\r\n]+).*', '$1'
    if ($home_ -notmatch '^[A-Z]:\\[^\r\n]+$') { $home_ = 'C:\Users\agent' }
    $home_ = $home_.Trim()
    $null = Invoke-Tool $Ctx.Mcp 'run' @{ machine = $Vm; command = 'Start-Process notepad -WindowStyle Maximized'; intent = 'Opening Notepad' }
    $t = Wait-PiWindow $Ctx $Vm 'Notepad|Bloc de notas'
    Check 'typing: the agent''s Notepad is in front' ($t -match 'Notepad|Bloc de notas') (($t -split "`n" | Select-Object -First 2) -join ' / ')
    Start-Sleep -Seconds 2

    $clicked = Click-PiPicture 0.5 0.55
    $n = Wait-Notch $script:PiControl 8
    Check 'typing: the first click on Notepad takes control' ($clicked -and $n -and $n.Text -match $script:PiControl) "text: $($n.Text)"
    Start-Sleep -Seconds 2
    $null = Click-PiPicture 0.5 0.55
    Start-Sleep -Milliseconds 500
    $front = [E2E]::Foreground() -like 'GpuVMViewer/*'
    Check 'typing: the picture has the keyboard' $front "foreground: $([E2E]::Foreground())"
    if ($front) { [PI35]::Type("e2e-human-$Tag") }
    Start-Sleep -Milliseconds 600
    [E2E]::Combo([byte][char]'A')
    $back = Invoke-Tool $Ctx.Mcp 'wait_for_person' @{ machine = $Vm; waitSeconds = 15 }
    Check 'typing: Ctrl+Alt+Shift+A gives the machine back' ($back -match "handed .* back|isn't paused") $back

    $intent = 'Working in Notepad'
    $pending = Start-Tool $Ctx.Mcp 'run' @{ machine = $Vm; command = 'Start-Sleep -Seconds 6'; intent = $intent }
    $null = Wait-Notch $intent 5
    $front = [E2E]::Foreground() -like 'GpuVMViewer/*'
    if ($front) { [PI35]::Type('q') }
    $n = Wait-Notch $script:PiControl 8
    Check 'typing: a key while the agent works takes control' ($front -and $n -and $n.Text -match $script:PiControl) $(if ($front) { "text: $($n.Text)" } else { "the picture wasn't in front: $([E2E]::Foreground())" })
    $null = Receive-Mcp $Ctx.Mcp $pending
    Start-Sleep -Seconds 2
    $back = Return-PiAgent $Ctx $Vm
    Check 'typing: the agent has the machine again' ($back -match "handed .* back|isn't paused") $back

    $file = "$home_\Desktop\e2e-human-$Tag.txt"
    $null = Invoke-Tool $Ctx.Mcp 'act' @{ machine = $Vm; intent = 'Saving the note'; actions = @(
            @{ type = 'key'; keys = 'ctrl+s' }, @{ type = 'wait'; ms = 2000 }, @{ type = 'type'; text = $file }, @{ type = 'key'; keys = 'enter' }, @{ type = 'wait'; ms = 1500 }) }
    $saved = Wait-For { $r = Invoke-Tool $Ctx.Mcp 'read_file' @{ machine = $Vm; path = "Desktop\e2e-human-$Tag.txt" }; if ($r -match "e2e.human.$Tag") { $r } } 10
    if (-not $saved) { $saved = Invoke-Tool $Ctx.Mcp 'read_file' @{ machine = $Vm; path = "Desktop\e2e-human-$Tag.txt" } }
    Check 'typing: after the click, the person''s typing reached Notepad' ($saved -match "e2e.human.$Tag") $saved
    Check 'typing: the key pressed while the agent worked didn''t reach the machine' ($saved -match "e2e.human.$Tag" -and $saved -notmatch 'q') $saved
    $null = Invoke-Tool $Ctx.Mcp 'run' @{ machine = $Vm; command = 'Stop-Process -Name notepad -Force -ErrorAction SilentlyContinue' }
}

function Test-PiButtonOnly($Ctx, [string]$Vm) {
    $opts = Get-PiTakeControl
    Check 'Settings > Agents shows the Take control options' ([bool]$opts) ''
    if (-not $opts) { return }
    $wasInput = Test-PiSelected $opts.Input
    try {
        $null = Invoke-Element $opts.Button
        $set = Wait-For { $o = Get-PiTakeControl; $o -and (Test-PiSelected $o.Button) } 4
        Check 'Take control is set to Button only' ([bool]$set) ''
        if (-not $set) { return }
        $null = Use-Machine $Ctx

        $intent = 'Button only check'
        $pending = Start-Tool $Ctx.Mcp 'run' @{ machine = $Vm; command = 'Start-Sleep -Seconds 10'; intent = $intent }
        $null = Wait-Notch $intent 6
        $clicked = Click-PiPicture 0.4 0.6
        Start-Sleep -Milliseconds 2500
        $n = Get-Notch
        Check 'Button only: a click on the picture doesn''t pause the agent' ($clicked -and $n -and $n.Text -match $intent -and $n.Text -notmatch $script:PiControl) "text: $($n.Text)"
        $take = Find-PiNotchButton '^\W*(Take control|Tomar el control)\W*$'
        $pressed = Click-Element $take
        $n = Wait-Notch $script:PiControl 8
        Check 'Button only: the notch''s Take control button takes control' ($pressed -and $n -and $n.Text -match $script:PiControl) "text: $($n.Text)"
        $null = Receive-Mcp $Ctx.Mcp $pending

        $waiting = Start-Tool $Ctx.Mcp 'wait_for_person' @{ machine = $Vm; waitSeconds = 30 }
        $b = Wait-For { Find-PiNotchButton $script:PiBack } 5
        $pressed = Click-Element $b
        $answer = Text-Of (Receive-Mcp $Ctx.Mcp $waiting)
        Check 'Button only: the notch''s Return to agent hands the machine back' ($pressed -and $answer -match 'handed .* back') $answer
    }
    finally {
        $o = Get-PiTakeControl
        if ($o) {
            $null = Invoke-Element $(if ($wasInput) { $o.Input } else { $o.Button })
            $ok = Wait-For { $x = Get-PiTakeControl; $x -and (Test-PiSelected $(if ($wasInput) { $x.Input } else { $x.Button })) } 4
            Check 'Take control is restored' ([bool]$ok) $(if ($wasInput) { 'Click or key' } else { 'Button only' })
        }
        else { Check 'Take control is restored' $false 'Settings > Agents not found' }
        $null = Invoke-Element (Get-PiSide '^(Home|Inicio)$')
    }
}

function Test-PiRequestHuman($Ctx, [string]$Vm) {
    $asked = Invoke-Tool $Ctx.Mcp 'request_human' @{ machine = $Vm; message = 'End-to-end check: press Return to agent.' }
    Check 'request_human asks the person' ($asked -match 'Asked the person') $asked
    $waiting = Start-Tool $Ctx.Mcp 'wait_for_person' @{ machine = $Vm; waitSeconds = 60 }
    $b = Wait-For { Find-PiAppButton $script:PiBack } 15
    $pressed = Click-Element $b
    $answer = Text-Of (Receive-Mcp $Ctx.Mcp $waiting)
    Check 'request_human: a real click on Return to agent hands the machine back' ($pressed -and $answer -match 'handed .* back') $answer
}

function Find-PiAdminDock {
    $app = Get-App
    if (-not $app) { return $null }
    foreach ($w in Get-AppWindows) {
        if ($w.Handle -eq $app.MainWindowHandle) { continue }
        try {
            $root = Get-Element $w.Handle
            $deny = Find-Named $root '^\W*(Deny|Rechazar)\W*$' ([Windows.Automation.ControlType]::Button)
            if (-not $deny -or -not (Find-Named $root '^\W*(Allow|Permitir)\W*$' ([Windows.Automation.ControlType]::Button))) { continue }
            $box = $null
            foreach ($e in $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)) {
                if ($e.Current.ClassName -match '(^|\s)dock(\s|$)') { $box = $e.Current.BoundingRectangle; break }
            }
            if (-not $box) { $box = $deny.Current.BoundingRectangle }
            return [pscustomobject]@{ Root = $root; Deny = $deny; X = [int]$box.X; Y = [int]$box.Y; W = [int]$box.Width; H = [int]$box.Height }
        } catch { }
    }
    $null
}

function Test-PiAdminPrompt($Ctx, [string]$Vm) {
    $null = Use-Machine $Ctx
    $st = @{ Run = '' }
    Check-NoFlash 'admin dock appearing' { $st.Run = Invoke-Tool $Ctx.Mcp 'run' @{ machine = $Vm; command = 'Start-Process cmd -Verb RunAs'; background = $true; intent = 'Asking for administrator rights' } } 7000
    $dock = Wait-For { Find-PiAdminDock } 30
    if (-not $dock) {
        Shot 'person-input-no-admin-dock'
        Check 'admin prompt: GpuVM''s dock with Allow and Deny drops over the picture' $false "no dock within 30 s after the UAC prompt was asked for; run: $($st.Run)"
        return
    }
    Check 'admin prompt: GpuVM''s dock with Allow and Deny drops over the picture' $true (Get-Texts $dock.Root)
    Check-Drawn 'admin dock' $dock
    $v = Get-PiViewer
    Check 'admin prompt: the dock is over the picture' ($v -and $dock.X -ge $v.X - 2 -and $dock.X + $dock.W -le $v.X + $v.W + 2 -and $dock.Y -ge $v.Y - 2 -and $dock.Y + $dock.H -le $v.Y + $v.H + 2) "dock $($dock.X),$($dock.Y) $($dock.W)x$($dock.H)"
    Shot 'person-input-admin-dock'
    $deny = Wait-For { $d = Find-PiAdminDock; if ($d -and $d.Deny.Current.IsEnabled) { $d.Deny } } 5
    $pressed = Click-Element $deny
    $gone = Wait-For { -not (Find-PiAdminDock) } 10
    Check 'admin prompt: a real click on Deny closes the dock' ($pressed -and $gone) ''
    $count = Wait-For { $c = Invoke-Tool $Ctx.Mcp 'run' @{ machine = $Vm; command = '@(Get-Process consent -ErrorAction SilentlyContinue).Count' }; if ($c -match '(?m)^\s*0\s*$') { $c } } 15
    Check 'admin prompt: after Deny no consent.exe runs in the machine' ([bool]$count) $(if ($count) { $count } else { Invoke-Tool $Ctx.Mcp 'run' @{ machine = $Vm; command = 'Get-Process consent -ErrorAction SilentlyContinue | Format-Table -HideTableHeaders Id, SessionId | Out-String' } })
}

function Test-PiDrop($Ctx, [string]$Vm, [string]$Tag) {
    $temp = (Get-Item -LiteralPath ([IO.Path]::GetTempPath())).FullName
    $name = "e2e-drop-$Tag.txt"
    $path = Join-Path $temp $name
    Set-Content -LiteralPath $path -Value "e2e-dropped-$Tag" -Encoding utf8
    $before = @(Get-PiExplorers | ForEach-Object Handle)
    $win = $null
    $down = $false
    try {
        $null = Use-Machine $Ctx
        Start-Process explorer.exe "/select,`"$path`""
        $win = Wait-PiNewExplorer $before
        Check 'drop: Explorer opens on the file' ([bool]$win) ''
        if (-not $win) { return }
        $s = Screen
        [PI35]::Place([IntPtr]$win.Handle, $s.X + 20, $s.Y + 120, [Math]::Min(560, [int]($s.Width / 2) - 120), [Math]::Min(520, $s.Height - 200))
        Start-Sleep -Seconds 1
        $item = Wait-For { Find-Named $win.Element "^$([regex]::Escape("e2e-drop-$Tag"))(\.txt)?$" ([Windows.Automation.ControlType]::ListItem) } 8
        $r = if ($item) { $item.Current.BoundingRectangle } else { $null }
        $sx = if ($r) { [int]($r.X + [Math]::Min(40, $r.Width / 4)) } else { 0 }; $sy = if ($r) { [int]($r.Y + $r.Height / 2) } else { 0 }
        $to = Get-PiPoint 0.6 0.55
        $ready = $r -and $to -and [E2E]::ProcessNameAt($sx, $sy) -eq 'explorer' -and [E2E]::ProcessNameAt($to.X, $to.Y) -eq 'GpuVMViewer'
        Check 'drop: the file and the picture are both visible' ([bool]$ready) $(if ($r -and $to) { "at the file: $([E2E]::ProcessNameAt($sx, $sy)); at the target: $([E2E]::ProcessNameAt($to.X, $to.Y))" } else { 'file item or picture not found' })
        if (-not $ready) { return }

        [PI35]::To($sx, $sy); Start-Sleep -Milliseconds 150
        [PI35]::Down(); $down = $true; Start-Sleep -Milliseconds 150
        for ($i = 1; $i -le 30; $i++) { [PI35]::To($sx + ($to.X - $sx) * $i / 30, $sy + ($to.Y - $sy) * $i / 30); Start-Sleep -Milliseconds 25 }
        $zone = $null
        $deadline = (Get-Date).AddSeconds(5)
        $k = 0
        while (-not $zone -and (Get-Date) -lt $deadline) {
            $k++; [PI35]::To($to.X + ($k % 2) * 4, $to.Y + ($k % 3)); Start-Sleep -Milliseconds 60
            $zone = Find-PiDropZone
        }
        Shot 'person-input-drop'
        Check 'drop: during the drag GpuVM shows "Drop to send"' ([bool]$zone) ''
        [PI35]::To($to.X, $to.Y); Start-Sleep -Milliseconds 100
        [PI35]::Up(); $down = $false
        $got = Wait-For { $t = Invoke-Tool $Ctx.Mcp 'read_file' @{ machine = $Vm; path = "Desktop\Received\$name" }; if ($t -match "e2e-dropped-$Tag") { $t } } 40
        Check 'drop: the file arrives in Desktop\Received with its content' ([bool]$got) $(if ($got) { $got } else { Invoke-Tool $Ctx.Mcp 'read_file' @{ machine = $Vm; path = "Desktop\Received\$name" } })
    }
    finally {
        if ($down) { [PI35]::Up() }
        Close-PiExplorer $win
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Test-PiWidgets($Ctx, [string]$Vm, [string]$Tag) {
    $clip = "e2e-clip-$Tag"
    $oldClip = try { Get-Clipboard -Raw } catch { $null }
    $shown = $null
    $folder = $null
    try {
        $null = Use-Machine $Ctx
        Set-Clipboard -Value $clip
        $null = Click-PiPicture 0.35 0.45
        $null = Wait-For { [E2E]::Foreground() -like 'GpuVMViewer/*' } 3
        [E2E]::Combo([byte][char]'G')
        $panel = Wait-For { $p = Get-PiPanel; if ($p -and (Get-PiWidget $p '^(Capture|Captura)$')) { $p } } 8
        Check 'widgets: the side panel opens' ([bool]$panel) ''
        if (-not $panel) { return }

        $listed = Wait-For { $w = Get-PiWidget (Get-PiPanel) '^(Clipboard|Portapapeles)$'; if ($w -and (Get-Texts $w) -match [regex]::Escape($clip)) { $w } } 8
        Check 'Clipboard widget lists what was copied on the PC' ([bool]$listed) $(if (-not $listed) { "text: $(Get-Texts (Get-PiWidget (Get-PiPanel) '^(Clipboard|Portapapeles)$'))" } else { '' })
        $paste = $null
        if ($listed) {
            $walker = [Windows.Automation.TreeWalker]::ControlViewWalker
            $buttons = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button)
            foreach ($b in $listed.FindAll([Windows.Automation.TreeScope]::Descendants, $buttons)) {
                if ($b.Current.Name -notmatch '^(Paste in|Pegar en) ') { continue }
                $row = $walker.GetParent($b)
                if ($row -and (Get-Texts $row) -match [regex]::Escape($clip)) { $paste = $b; break }
            }
        }
        if ($paste) { Show-PiElement $paste }
        $pasted = Click-Element $paste
        Check "Clipboard widget: a real click on Paste in $Vm" $pasted $(if ($paste) { $paste.Current.Name } else { 'button not found' })
        Start-Sleep -Seconds 2

        $cap = Get-PiWidget (Get-PiPanel) '^(Capture|Captura)$'
        if ($cap) { Show-PiElement $cap }
        $before = Get-PiVideos $Vm
        $rec = if ($cap) { Find-Named $cap '^(Record|Grabar)$' ([Windows.Automation.ControlType]::Button) }
        $pressed = Click-Element $rec
        $n = Wait-Notch 'Recording|Grabando' 10
        Check 'Capture widget: Record shows Recording in the notch' ($pressed -and $n -and $n.Text -match 'Recording|Grabando') "text: $($n.Text)"
        Start-Sleep -Seconds 3
        $stop = Wait-For { $w = Get-PiWidget (Get-PiPanel) '^(Capture|Captura)$'; if ($w) { Find-Named $w '^(Stop|Detener)\b' ([Windows.Automation.ControlType]::Button) } } 4
        $pressed = Click-Element $stop
        $n = Wait-Notch 'Recording saved|Grabaci.n guardada' 20
        Check 'Capture widget: Stop says Recording saved' ($pressed -and $n -and $n.Text -match 'Recording saved|Grabaci.n guardada') "text: $($n.Text)"
        $file = Wait-For { Get-PiVideos $Vm | Where-Object { $before -notcontains $_ -and $_ -match '\.(mp4|mkv|mov)$' -and (Get-Item -LiteralPath $_).Length -gt 0 } | Select-Object -First 1 } 30
        Check "Capture widget: a new video is saved in Videos\GpuVM\$Vm" ([bool]$file) $(if ($file) { $file } else { 'no new video file' })

        $reveal = Wait-For { $w = Get-PiWidget (Get-PiPanel) '^(Capture|Captura)$'; if ($w) { Find-Named $w '^(Show in folder|Mostrar en la carpeta)$' ([Windows.Automation.ControlType]::Button) } } 6
        if ($reveal) { Show-PiElement $reveal }
        $windows = @(Get-PiExplorers | ForEach-Object Handle)
        $pressed = Click-Element $reveal
        $folder = Wait-PiNewExplorer $windows 12
        Check 'Capture widget: Show in folder opens Explorer on the folder' ($pressed -and $folder -and $folder.Name -match [regex]::Escape($Vm)) $(if ($folder) { "window: $($folder.Name)" } else { 'no new Explorer window' })
        Close-PiExplorer $folder; $folder = $null

        $null = Use-Machine $Ctx
        $p = Get-PiPanel
        if ($p) { [E2E]::Click($p.X + 24, $p.Y + 22); Start-Sleep -Milliseconds 300; [E2E]::Combo([byte][char]'G') }
        Check 'widgets: the side panel closes' ([bool](Wait-For { -not (Get-PiPanel) } 5)) ''

        $back = Return-PiAgent $Ctx $Vm
        Check 'widgets: the agent has the machine again' ($back -match "handed .* back|isn't paused") $back
        if ($pasted) {
            $got = Wait-For { $t = Invoke-Tool $Ctx.Mcp 'run' @{ machine = $Vm; command = 'Get-Clipboard -Raw' }; if ($t -match [regex]::Escape($clip)) { $t } } 15
            Check 'Clipboard widget: the text is on the machine''s clipboard' ([bool]$got) $(if ($got) { $got } else { Invoke-Tool $Ctx.Mcp 'run' @{ machine = $Vm; command = 'Get-Clipboard -Raw' } })
        }
    }
    finally {
        Close-PiExplorer $folder
        try { if (Get-PiPanel) { $p = Get-PiPanel; [E2E]::Click($p.X + 24, $p.Y + 22); Start-Sleep -Milliseconds 300; [E2E]::Combo([byte][char]'G') } } catch { }
        if ($oldClip) { try { Set-Clipboard -Value $oldClip } catch { } }
    }
}

function Test-Suite($Ctx) {
    $vm = Use-Machine $Ctx
    $tag = "$(Get-Random -Minimum 100000 -Maximum 999999)"
    $null = Return-PiAgent $Ctx $vm
    Start-Sleep -Seconds 2
    $steps = [ordered]@{
        'hovering' = { Test-PiHover $Ctx $vm }
        'typing' = { Test-PiTyping $Ctx $vm $tag }
        'button only' = { Test-PiButtonOnly $Ctx $vm }
        'request_human' = { Test-PiRequestHuman $Ctx $vm }
        'admin prompt' = { Test-PiAdminPrompt $Ctx $vm }
        'drop' = { Test-PiDrop $Ctx $vm $tag }
        'widgets' = { Test-PiWidgets $Ctx $vm $tag }
    }
    try {
        foreach ($name in $steps.Keys) {
            try { & $steps[$name] } catch { Check "person input: $name ran to the end" $false $_.Exception.Message }
            try { $null = Use-Machine $Ctx; $null = Return-PiAgent $Ctx $vm } catch { }
            Start-Sleep -Seconds 2
        }
    }
    finally {
        try { $null = Return-PiAgent $Ctx $vm } catch { }
        $null = Invoke-Tool $Ctx.Mcp 'take_machine' @{ machine = $vm }
        try { $null = Use-Machine $Ctx } catch { }
        Check 'the agent holds the machine, not paused, at the end' (-not (Test-PiPaused $Ctx $vm)) ''
    }
}
