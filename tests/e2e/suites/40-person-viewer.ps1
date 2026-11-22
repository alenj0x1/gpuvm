# What the person does with a machine's picture: the viewer's shortcuts, full screen, the side panel and its widgets,
# going Home and back, and disconnecting.
if (-not ('PV40' -as [type])) {
    Add-Type @'
using System; using System.Runtime.InteropServices;
public static class PV40 {
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  public static void Drag(int x1, int y1, int x2, int y2) {
    SetCursorPos(x1, y1); System.Threading.Thread.Sleep(80); mouse_event(2, 0, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(80);
    for (int i = 1; i <= 20; i++) { SetCursorPos(x1 + (x2 - x1) * i / 20, y1 + (y2 - y1) * i / 20); System.Threading.Thread.Sleep(25); }
    System.Threading.Thread.Sleep(120); mouse_event(4, 0, 0, 0, IntPtr.Zero);
  }
}
'@
}

$script:PvWidgets = [ordered]@{
    machines = '^(Machines|M.quinas)$'; actions = '^(Actions|Acciones)$'; capture = '^(Capture|Captura)$'; stats = '^(Picture|Imagen)$'
    clock = '^(Clock|Reloj)$'; files = '^(Files|Archivos)$'; clipboard = '^(Clipboard|Portapapeles)$'; shelf = '^(Shelf|Estanter.a)$'; games = '^(Games|Juegos)$'
}
$script:PvOptional = '^(Agent|Agente|Weather|Clima)$'

function Get-PvViewer {
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

function Test-PvPicture {
    $v = Get-PvViewer
    $v -and [E2E]::ProcessNameAt($v.X + [int]($v.W / 4), $v.Y + [int]($v.H / 2)) -eq 'GpuVMViewer'
}

function Test-PvFull($V) {
    if (-not $V) { return $false }
    $b = [Windows.Forms.Screen]::FromHandle($V.Handle).Bounds
    $V.X -le $b.X -and $V.Y -le $b.Y -and $V.X + $V.W -ge $b.Right -and $V.Y + $V.H -ge $b.Bottom
}

function Get-PvAppRect { $app = Get-App; if ($app) { $r = [E2E]::Rect($app.MainWindowHandle); [pscustomobject]@{ X = $r[0]; Y = $r[1]; W = $r[2]; H = $r[3] } } }

function Test-PvAppShown {
    $a = Get-PvAppRect
    $a -and [E2E]::ProcessNameAt($a.X + [int]($a.W / 2), $a.Y + [int]($a.H / 2)) -eq 'gpuvm'
}

function Check-PvMode([string]$Name, [bool]$Full) {
    $v = Get-PvViewer
    if ($Full) {
        Check "${Name}: the picture covers the monitor" (Test-PvFull $v) $(if ($v) { "viewer at $($v.X),$($v.Y) $($v.W)x$($v.H)" } else { 'no viewer window' })
        return
    }
    $a = Get-PvAppRect
    $inside = $v -and $a -and $v.X -ge $a.X - 2 -and $v.Y -ge $a.Y - 2 -and $v.X + $v.W -le $a.X + $a.W + 2 -and $v.Y + $v.H -le $a.Y + $a.H + 2
    Check "${Name}: the picture is inside the app's window" ([bool]($inside -and -not (Test-PvFull $v))) $(if ($v -and $a) { "viewer $($v.X),$($v.Y) $($v.W)x$($v.H); app $($a.X),$($a.Y) $($a.W)x$($a.H)" } else { 'window missing' })
}

function Focus-PvPicture {
    $v = Get-PvViewer
    if (-not $v) { return $false }
    $x = $v.X + [int]($v.W * 0.35); $y = $v.Y + [int]($v.H * 0.4)
    [E2E]::Click($x, $y)
    if (Wait-For { [E2E]::Foreground() -like 'GpuVMViewer/*' } 3) { return $true }
    # Logged for the report: what took the click instead of the picture.
    Write-Host "     the click on the picture at $x,$y left $([E2E]::Foreground()) in front (window there: $([E2E]::At($x, $y))); clicking again"
    [E2E]::Click($x, $y)
    [bool](Wait-For { [E2E]::Foreground() -like 'GpuVMViewer/*' } 3)
}

function Get-PvPanel {
    $app = Get-App
    if (-not $app) { return $null }
    foreach ($w in Get-AppWindows) {
        if ($w.Handle -eq $app.MainWindowHandle -or $w.W -lt 250 -or $w.H -lt 300) { continue }
        $root = Get-Element $w.Handle
        if (Find-Named $root '^(Viewer panel|Panel del visor)$') { return [pscustomobject]@{ Handle = $w.Handle; X = $w.X; Y = $w.Y; W = $w.W; H = $w.H; Root = $root } }
    }
    $null
}

function Get-PvWidgets($Panel) {
    if (-not $Panel) { return @() }
    foreach ($e in $Panel.Root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)) {
        $c = $e.Current
        if ($c.ClassName -notmatch '\bvp-widget\b') { continue }
        $r = $c.BoundingRectangle
        [pscustomobject]@{ Name = $c.Name; Element = $e; X = $r.X; Y = $r.Y; W = $r.Width; H = $r.Height }
    }
}

function Get-PvWidget($Panel, [string]$Key) { Get-PvWidgets $Panel | Where-Object { $_.Name -match $script:PvWidgets[$Key] } | Select-Object -First 1 }

function Get-PvButton($Root, [string]$Pattern) { Find-Named $Root $Pattern ([Windows.Automation.ControlType]::Button) }

function Get-PvActionsDetail($Panel, $Act) {
    if (-not $Panel) { return "no side panel; in front: $([E2E]::Foreground())" }
    if (-not $Act) { return "no Actions widget; widgets: $((Get-PvWidgets $Panel | ForEach-Object Name) -join ', ')" }
    "buttons: $((@($Act.Element.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button))) | ForEach-Object { $_.Current.Name }) -join ', ')"
}

function Open-PvPanel {
    if (-not (Focus-PvPicture)) { return $null }
    [E2E]::Combo([byte][char]'G')
    Wait-For { $p = Get-PvPanel; if ($p -and @(Get-PvWidgets $p).Count) { $p } } 8
}

function Close-PvPanel([string]$Name) {
    $p = Get-PvPanel
    if (-not $p) { return }
    [E2E]::Click($p.X + 24, $p.Y + 22)
    Start-Sleep -Milliseconds 300
    Check-NoFlash $Name { [E2E]::Combo([byte][char]'G') }
    Check "${Name}: the panel window goes away" ([bool](Wait-For { -not (Get-PvPanel) } 4)) ''
}

function Check-PvInside([string]$Name) {
    $p = Get-PvPanel
    $ws = @(Get-PvWidgets $p | Where-Object { $_.W -gt 0 -and -not [double]::IsInfinity($_.X) })
    $out = @($ws | Where-Object { $_.W -gt $p.W + 1 -or $_.X -lt $p.X - 1 -or $_.X + $_.W -gt $p.X + $p.W + 1 })
    Check "${Name}: no widget is wider than the panel or outside it" ($p -and $ws.Count -and -not $out.Count) "panel $($p.W) px wide; $($ws.Count) widgets; outside: $(($out | ForEach-Object { "$($_.Name) $([int]$_.X)+$([int]$_.W)" }) -join ', ')"
}

function Get-PvCaptureDirs([switch]$Video) {
    $dirs = [Collections.Generic.List[string]]::new()
    $dirs.Add((Join-Path ([Environment]::GetFolderPath($(if ($Video) { 'MyVideos' } else { 'MyPictures' }))) 'GpuVM'))
    $override = if ($Video) { $env:GPUVM_E2E_VIDEOS } else { $env:GPUVM_E2E_SHOTS }
    if ($override) { $dirs.Add($override) }
    $pattern = '"' + $(if ($Video) { 'videosDir' } else { 'shotsDir' }) + '":"((?:[^"\\]|\\.)+)"'
    $ldb = Join-Path $env:LOCALAPPDATA 'dev.alejandro.gpuvm\EBWebView\Default\Local Storage\leveldb'
    foreach ($f in Get-ChildItem -LiteralPath $ldb -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.log', '.ldb' }) {
        try {
            $fs = [IO.FileStream]::new($f.FullName, 'Open', 'Read', 'ReadWrite, Delete'); $ms = [IO.MemoryStream]::new(); $fs.CopyTo($ms); $fs.Dispose(); $bytes = $ms.ToArray()
        } catch { continue }
        if ($bytes.Length -lt 2) { continue }
        $texts = @([Text.Encoding]::GetEncoding(28591).GetString($bytes), [Text.Encoding]::Unicode.GetString($bytes), [Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1))
        foreach ($t in $texts) { foreach ($m in [regex]::Matches($t, $pattern)) { $dirs.Add(($m.Groups[1].Value -replace '\\\\', '\')) } }
    }
    @($dirs | Select-Object -Unique)
}

function Get-PvFiles($Dirs, [string]$Vm) { @(foreach ($d in $Dirs) { Get-ChildItem -LiteralPath (Join-Path $d $Vm) -File -ErrorAction SilentlyContinue | ForEach-Object FullName }) }

function Wait-PvNewFile($Dirs, [string]$Vm, $Before, [string]$Pattern, [double]$Seconds) {
    Wait-For { @(Get-PvFiles $Dirs $Vm | Where-Object { $Before -notcontains $_ -and $_ -match $Pattern -and (Get-Item -LiteralPath $_).Length -gt 0 }) | Select-Object -First 1 } $Seconds
}

function Find-PvOpen([string]$Vm) {
    $root = Get-MainElement
    if (-not $root) { return $null }
    $buttons = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button)
    $walker = [Windows.Automation.TreeWalker]::ControlViewWalker
    foreach ($b in $root.FindAll([Windows.Automation.TreeScope]::Descendants, $buttons)) {
        if ($b.Current.Name -notmatch '^(Open|Abrir)$' -or $b.Current.IsOffscreen) { continue }
        $up = $b
        for ($i = 0; $i -lt 6; $i++) {
            $up = $walker.GetParent($up)
            if (-not $up) { break }
            if ((Get-Texts $up) -match [regex]::Escape($Vm)) {
                $n = @($up.FindAll([Windows.Automation.TreeScope]::Descendants, $buttons) | Where-Object { $_.Current.Name -match '^(Open|Abrir)$' }).Count
                if ($n -eq 1) { return $b }
                break
            }
        }
    }
    $null
}

function Open-PvFromApp([string]$Name, [string]$Vm, [double]$Seconds) {
    $open = Wait-For { Find-PvOpen $Vm } 8
    if (-not $open) {
        $row = Find-Named (Get-MainElement) "^$([regex]::Escape($Vm))`$" ([Windows.Automation.ControlType]::Button)
        if (-not $row) { $row = Find-Named (Get-MainElement) ([regex]::Escape($Vm)) }
        if ($row) { $null = Invoke-Element $row }
        $open = Wait-For { Find-PvOpen $Vm } 12
    }
    Check "${Name}: the app shows Open for the machine" ([bool]$open) ''
    if (-not $open) { return $false }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $null = Invoke-Element $open
    $back = Wait-For { Test-PvPicture } $Seconds
    Check "${Name}: the picture is back in front" ([bool]$back) ("{0:N1} s" -f $sw.Elapsed.TotalSeconds)
    [bool]$back
}

function Test-Suite($Ctx) {
    $vm = Use-Machine $Ctx
    $null = Invoke-Tool $Ctx.Mcp 'release_machine' @{ machine = $vm }
    Start-Sleep -Seconds 2
    try {
        Check 'the picture is shown' (Test-PvPicture) ''
        $startFull = Test-PvFull (Get-PvViewer)
        Check-PvMode 'opened' $startFull
        Shot 'person-1-opened'

        $shotDirs = Get-PvCaptureDirs
        $before = Get-PvFiles $shotDirs $vm
        Check 'the picture takes the keyboard after a click' (Focus-PvPicture) "foreground: $([E2E]::Foreground())"
        [E2E]::Combo([byte][char]'P')
        $n = Wait-Notch 'Screenshot saved|Captura guardada' 10
        Check 'Ctrl+Alt+Shift+P: the notch says the screenshot was saved' ($n -and $n.Text -match 'Screenshot saved|Captura guardada') "text: $($n.Text)"
        $file = Wait-PvNewFile $shotDirs $vm $before '\.(png|jpe?g|bmp|webp)$' 15
        Check 'Ctrl+Alt+Shift+P: a new screenshot file is saved' ([bool]$file) $(if ($file) { $file } else { "looked in: $($shotDirs -join '; ')" })

        $videoDirs = Get-PvCaptureDirs -Video
        $before = Get-PvFiles $videoDirs $vm
        $null = Focus-PvPicture
        [E2E]::Combo([byte][char]'R')
        $n = Wait-Notch 'Recording|Grabando' 10
        Check 'Ctrl+Alt+Shift+R: the notch shows Recording' ($n -and $n.Text -match 'Recording|Grabando') "text: $($n.Text)"
        Shot 'person-2-recording'
        Start-Sleep -Seconds 4
        $null = Focus-PvPicture
        [E2E]::Combo([byte][char]'R')
        $gone = Wait-For { $x = Get-Notch; -not ($x -and $x.Text -match '(Recording|Grabando)(?!\s*(saved|guardad))') } 10
        Check 'Ctrl+Alt+Shift+R again: recording stops' ([bool]$gone) "notch: $((Get-Notch).Text)"
        $file = Wait-PvNewFile $videoDirs $vm $before '\.(mp4|mkv|mov)$' 30
        Check 'Ctrl+Alt+Shift+R: a video file is saved after stopping' ([bool]$file) $(if ($file) { $file } else { "looked in: $($videoDirs -join '; ')" })

        $null = Focus-PvPicture
        [E2E]::Combo([byte][char]'X')
        $flipped = Wait-For { (Test-PvFull (Get-PvViewer)) -ne $startFull } 8
        Check 'Ctrl+Alt+Shift+X switches full screen' ([bool]$flipped) ''
        Start-Sleep -Seconds 1
        Check-PvMode 'Ctrl+Alt+Shift+X' (-not $startFull)
        Check 'Ctrl+Alt+Shift+X: the picture stays in front' (Test-PvPicture) ''
        Shot 'person-3-fullscreen-toggled'
        $null = Focus-PvPicture
        [E2E]::Combo([byte][char]'X')
        $restored = Wait-For { (Test-PvFull (Get-PvViewer)) -eq $startFull } 8
        Check 'Ctrl+Alt+Shift+X again switches back' ([bool]$restored) ''
        Start-Sleep -Seconds 1
        Check-PvMode 'Ctrl+Alt+Shift+X twice' $startFull

        $panel = Open-PvPanel
        Check 'Ctrl+Alt+Shift+G opens the side panel' ([bool]$panel) ''
        if ($panel) {
            Start-Sleep -Milliseconds 800
            $panel = Get-PvPanel
            Shot 'person-4-panel'
            $v = Get-PvViewer
            Check 'the panel sits at the right edge of the picture' ($v -and [Math]::Abs(($panel.X + $panel.W) - ($v.X + $v.W)) -le 4) "panel right $($panel.X + $panel.W), picture right $($v.X + $v.W)"
            Check 'the panel shows the machine''s name' ((Get-Texts $panel.Root) -match [regex]::Escape($vm)) ''

            $widgets = @(Get-PvWidgets $panel)
            $known = @($script:PvWidgets.Values) + $script:PvOptional
            $untitled = @($widgets | Where-Object { $n = $_.Name; -not ($known | Where-Object { $n -match $_ }) })
            Check 'every widget has its title' ($widgets.Count -and -not $untitled.Count) "$($widgets.Count) widgets; without a known title: $(($untitled | ForEach-Object { "'$($_.Name)'" }) -join ', ')"
            foreach ($key in $script:PvWidgets.Keys) {
                $w = Get-PvWidget $panel $key
                Check "widget $key is on the panel" ([bool]$w) $(if ($w) { $w.Name } else { 'missing' })
            }

            $m = Get-PvWidget $panel 'machines'
            $mt = if ($m) { Get-Texts $m.Element } else { '' }
            Check 'Machines lists the machine (or says there are no others)' ($mt -match "$([regex]::Escape($vm))|No other machines|Sin otras m.quinas") "text: $mt"

            $c = Get-PvWidget $panel 'clock'
            $ct = if ($c) { Get-Texts $c.Element } else { '' }
            $times = foreach ($d in (Get-Date), (Get-Date).AddMinutes(-1)) { $d.ToString('H:mm'); $d.ToString('h:mm') }
            Check 'Clock shows the time' ([bool]($times | Where-Object { $ct -match "(^|\D)$([regex]::Escape($_))(\D|$)" })) "text: $ct; expected one of $($times -join ', ')"

            foreach ($key in 'files', 'clipboard') {
                $w = Get-PvWidget $panel $key
                $wt = if ($w) { Get-Texts $w.Element } else { '' }
                Check "widget $key renders its content" ($w -and $w.W -gt 40 -and $w.H -gt 40 -and $wt) "text: $wt"
            }

            $cap = Get-PvWidget $panel 'capture'
            $shot = if ($cap) { Get-PvButton $cap.Element '^(Screenshot|Capturar)$' }
            Check 'Capture has a Screenshot button' ([bool]$shot) ''
            if ($shot) {
                $before = Get-PvFiles $shotDirs $vm
                $null = Invoke-Element $shot
                $file = Wait-PvNewFile $shotDirs $vm $before '\.(png|jpe?g|bmp|webp)$' 15
                Check 'Capture''s Screenshot button saves a file' ([bool]$file) $(if ($file) { $file } else { "looked in: $($shotDirs -join '; ')" })
                if ($file) {
                    $leaf = Split-Path $file -Leaf
                    $shown = Wait-For { $w = Get-PvWidget (Get-PvPanel) 'capture'; $w -and (Get-Texts $w.Element) -match [regex]::Escape($leaf) } 8
                    Check 'Capture shows the saved file' ([bool]$shown) $leaf
                }
            }

            $sig = { $p = Get-PvPanel; (@(Get-PvWidgets $p | Sort-Object Name | ForEach-Object { "$($_.Name):$([int]$_.X):$([int]$_.W):$([int]$_.H)" }) -join ';') }
            $layout = & $sig
            $edit = Get-PvButton $panel.Root '^(Edit|Editar)$'
            Check 'the panel has Edit' ([bool]$edit) ''
            if ($edit) {
                $null = Invoke-Element $edit
                $done = Wait-For { Get-PvButton (Get-PvPanel).Root '^(Done|Listo)$' } 5
                Check 'Edit turns on edit mode (Done shows)' ([bool]$done) ''
                $pp = Get-PvPanel
                $removes = if ($pp) { @($pp.Root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.Name -match '^(Remove|Quitar)$' }).Count } else { 0 }
                Check 'edit mode offers to remove widgets' ($removes -gt 0) "$removes remove buttons"
                Shot 'person-5-edit'
                if ($done) { $null = Invoke-Element $done }
                $back = Wait-For { Get-PvButton (Get-PvPanel).Root '^(Edit|Editar)$' } 5
                Check 'Done leaves edit mode' ([bool]$back) ''
                Start-Sleep -Milliseconds 800
                $after = & $sig
                Check 'leaving edit mode without changes keeps the layout' ($after -eq $layout) $(if ($after -ne $layout) { "before: $layout / after: $after" } else { '' })
            }

            Check-PvInside 'panel as opened'
            $p0 = Get-PvPanel
            $y = $p0.Y + [int]($p0.H / 2)
            [PV40]::Drag($p0.X + 3, $y, $p0.X + 3 - 180, $y)
            Start-Sleep -Milliseconds 1000
            $p1 = Get-PvPanel
            Check-PvInside 'panel widened'
            [PV40]::Drag($p1.X + 3, $y, $p1.X + $p1.W - 260, $y)
            Start-Sleep -Milliseconds 1000
            $p2 = Get-PvPanel
            Check-PvInside 'panel narrowed'
            Check 'dragging the panel''s edge resizes it' ($p1.W -ne $p0.W -or $p2.W -ne $p1.W) "widths $($p0.W) -> $($p1.W) -> $($p2.W) px"
            Shot 'person-6-panel-resized'
            [PV40]::Drag($p2.X + 3, $y, $p2.X + $p2.W - $p0.W + 3, $y)
            Start-Sleep -Milliseconds 800
            Check 'the panel goes back to its width' ([Math]::Abs((Get-PvPanel).W - $p0.W) -le 6) "$((Get-PvPanel).W) vs $($p0.W) px"

            $act = Get-PvWidget (Get-PvPanel) 'actions'
            $fs = if ($act) { Get-PvButton $act.Element '^(Full screen|Pantalla completa|Inside GpuVM|Dentro de GpuVM)$' }
            Check 'Actions has the full screen switch' ([bool]$fs) ''
            if ($fs) {
                $null = Invoke-Element $fs
                $flipped = Wait-For { (Test-PvFull (Get-PvViewer)) -ne $startFull } 8
                Check 'Actions: full screen switches' ([bool]$flipped) ''
                Start-Sleep -Seconds 1
                Check-PvMode 'Actions full screen' (-not $startFull)
                $p = Get-PvPanel; $v = Get-PvViewer
                Check 'Actions full screen: the panel follows the picture' ($p -and $v -and [Math]::Abs(($p.X + $p.W) - ($v.X + $v.W)) -le 4 -and $p.H -ge $v.H - 4) $(if ($p -and $v) { "panel $($p.X),$($p.Y) $($p.W)x$($p.H); picture $($v.X),$($v.Y) $($v.W)x$($v.H)" } else { 'window missing' })
                Shot 'person-7-actions-fullscreen'
                $act = Get-PvWidget (Get-PvPanel) 'actions'
                $fs = if ($act) { Get-PvButton $act.Element '^(Full screen|Pantalla completa|Inside GpuVM|Dentro de GpuVM)$' }
                if ($fs) { $null = Invoke-Element $fs }
                $restored = Wait-For { (Test-PvFull (Get-PvViewer)) -eq $startFull } 8
                Check 'Actions: full screen switches back' ([bool]$restored) ''
                Start-Sleep -Seconds 1
            }

            Close-PvPanel 'Ctrl+Alt+Shift+G closing the side panel'
            Check 'the picture is in front after closing the panel' ([bool](Wait-For { Test-PvPicture } 3)) ''
        }

        $panel = Open-PvPanel
        $act = Get-PvWidget $panel 'actions'
        $homeBtn = if ($act) { Get-PvButton $act.Element '^(Home|Inicio)$' }
        Check 'Actions has Home' ([bool]$homeBtn) (Get-PvActionsDetail $panel $act)
        if ($homeBtn) {
            $null = Invoke-Element $homeBtn
            $left = Wait-For { -not (Test-PvPicture) -and (Test-PvAppShown) } 8
            Check 'Actions Home hides the picture and shows the app' ([bool]$left) "at the app's center: $(if ($a = Get-PvAppRect) { [E2E]::ProcessNameAt($a.X + [int]($a.W / 2), $a.Y + [int]($a.H / 2)) })"
            Shot 'person-8-home'
            $null = Open-PvFromApp 'reopening after Actions Home' $vm 10
        }

        for ($i = 1; $i -le 3; $i++) {
            if (-not (Test-PvPicture)) { Check "Home and back ($i): starts from the picture" $false ''; break }
            $null = Focus-PvPicture
            Check-NoFlash "Ctrl+Alt+Shift+H going Home ($i)" { [E2E]::Combo([byte][char]'H') }
            Check "Ctrl+Alt+Shift+H ($i) hides the picture" ([bool](Wait-For { -not (Test-PvPicture) -and (Test-PvAppShown) } 6)) ''
            $open = Wait-For { Find-PvOpen $vm } 20
            Check "Home ($i): the app shows Open for the machine" ([bool]$open) ''
            if (-not $open) { break }
            Check-NoFlash "back to the picture ($i)" { $null = Invoke-Element $open } 4000
            Check "back to the picture ($i): it is in front" ([bool](Wait-For { Test-PvPicture } 10)) ''
        }

        $panel = Open-PvPanel
        $act = Get-PvWidget $panel 'actions'
        $quit = if ($act) { Get-PvButton $act.Element '^(Disconnect|Desconectar)$' }
        Check 'Actions has Disconnect' ([bool]$quit) (Get-PvActionsDetail $panel $act)
        if ($quit) {
            Check-NoFlash 'closing the viewer' { $null = Invoke-Element $quit } 4000
            $closed = Wait-For { -not (Get-Process GpuVMViewer -ErrorAction SilentlyContinue) } 15
            Check 'Actions Disconnect closes the viewer' ([bool]$closed) ''
            Check 'Disconnect closes the panel too' ([bool](Wait-For { -not (Get-PvPanel) } 4)) ''
            Shot 'person-9-disconnected'
            $null = Open-PvFromApp 'reopening after Disconnect' $vm 120
            Shot 'person-10-reopened'
        }
    }
    finally {
        try {
            if (Get-PvPanel) { [E2E]::Combo([byte][char]'G') }
        } catch { }
        $null = Invoke-Tool $Ctx.Mcp 'take_machine' @{ machine = $vm }
        try { if (-not (Test-PvPicture)) { $null = Use-Machine $Ctx } } catch { }
    }
}
