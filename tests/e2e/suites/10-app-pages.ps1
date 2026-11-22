# Every page of the main window, driven through UI Automation: the sidebar, Home and its create dialog, the Library
# tabs, Agents, every Settings section (a theme change measured on screen, then restored) and the machine pages.
if (-not ('E2EPages' -as [type])) {
    Add-Type @'
using System; using System.Runtime.InteropServices;
public static class E2EPages {
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint f, IntPtr e);
  public static bool Front(IntPtr h) {
    if (GetForegroundWindow() == h) return true;
    if (IsIconic(h)) ShowWindow(h, 9);
    keybd_event(0x12, 0, 0, IntPtr.Zero); keybd_event(0x12, 0, 2, IntPtr.Zero);
    SetForegroundWindow(h); System.Threading.Thread.Sleep(250);
    return GetForegroundWindow() == h;
  }
  public static void Key(byte vk) { keybd_event(vk, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(40); keybd_event(vk, 0, 2, IntPtr.Zero); }
  // BGRA bytes: share of colored or mid-gray pixels in b, and share of pixels that differ between a and b.
  public static double[] Life(byte[] a, byte[] b) {
    int mid = 0, moved = 0, n = 0;
    for (int i = 0; i + 3 < b.Length && i + 3 < a.Length; i += 8) {
      int s = b[i] + b[i+1] + b[i+2], mx = Math.Max(b[i], Math.Max(b[i+1], b[i+2])), mn = Math.Min(b[i], Math.Min(b[i+1], b[i+2]));
      if ((s > 150 && s < 650) || mx - mn > 40) mid++;
      if (Math.Abs(a[i] - b[i]) + Math.Abs(a[i+1] - b[i+1]) + Math.Abs(a[i+2] - b[i+2]) > 30) moved++;
      n++;
    }
    return new[] { (double)mid / n, (double)moved / n };
  }
}
'@
}

$script:UIA = [Windows.Automation.AutomationElement]
$script:Desc = [Windows.Automation.TreeScope]::Descendants

function Show-Main {
    $app = Get-App
    if (-not $app) { return $false }
    try { (Get-MainElement).SetFocus() } catch { }
    [E2EPages]::Front($app.MainWindowHandle)
}

function Get-MainRect {
    $r = [E2E]::Rect((Get-App).MainWindowHandle); $s = Screen
    $x = [Math]::Max($r[0] + 8, $s.X); $y = [Math]::Max($r[1] + 8, $s.Y)
    $w = [Math]::Min($r[0] + $r[2] - 8, $s.X + $s.Width) - $x; $h = [Math]::Min($r[1] + $r[3] - 8, $s.Y + $s.Height) - $y
    [pscustomobject]@{ X = $x; Y = $y; W = $w; H = $h }
}

function Get-Area([int]$X, [int]$Y, [int]$W, [int]$H) {
    $bmp = Grab $X $Y ([Math]::Max(1, $W)) ([Math]::Max(1, $H)); $b = Bytes $bmp; $bmp.Dispose(); , $b
}

function Get-WindowTones { $r = Get-MainRect; [E2E]::Tones((Get-Area $r.X $r.Y $r.W $r.H)) }

function Find-Text($Root, [string[]]$Names) {
    if (-not $Root) { return $null }
    $c = @($Names | ForEach-Object { [Windows.Automation.PropertyCondition]::new($script:UIA::NameProperty, $_) })
    $cond = if ($c.Count -eq 1) { $c[0] } else { [Windows.Automation.OrCondition]::new([Windows.Automation.Condition[]]$c) }
    try { $Root.FindFirst($script:Desc, $cond) } catch { $null }
}

function Find-AllText($Root, [string[]]$Names) {
    if (-not $Root) { return @() }
    $c = @($Names | ForEach-Object { [Windows.Automation.PropertyCondition]::new($script:UIA::NameProperty, $_) })
    $cond = if ($c.Count -eq 1) { $c[0] } else { [Windows.Automation.OrCondition]::new([Windows.Automation.Condition[]]$c) }
    try { @($Root.FindAll($script:Desc, $cond)) } catch { @() }
}

function Find-Typed($Root, $Type, [string]$Pattern = '.') {
    if (-not $Root) { return @() }
    $cond = [Windows.Automation.PropertyCondition]::new($script:UIA::ControlTypeProperty, $Type)
    @($Root.FindAll($script:Desc, $cond) | Where-Object { $_.Current.Name -match $Pattern })
}

function Test-OnScreen($Element) {
    if (-not $Element) { return $false }
    try { $c = $Element.Current } catch { return $false }
    $r = $c.BoundingRectangle; $w = Get-MainRect
    -not $c.IsOffscreen -and $r.Width -gt 0 -and $r.Y -ge $w.Y - 2 -and $r.Y + $r.Height -le $w.Y + $w.H + 10
}

function Test-Selected($Element) {
    $p = $null
    try {
        if ($Element.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { return $p.Current.IsSelected }
        if ($Element.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern, [ref]$p)) { return $p.Current.ToggleState -eq 'On' }
    } catch { }
    $false
}

function Select-Option($Element) {
    $null = Invoke-Element $Element
    if (Wait-For { Test-Selected $Element } 2) { return $true }
    $null = Show-Main
    $r = $Element.Current.BoundingRectangle
    [E2E]::Click([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2))
    [bool](Wait-For { Test-Selected $Element } 2)
}

function Get-SideButtons {
    @(Find-Typed (Get-MainElement) ([Windows.Automation.ControlType]::Button) | Where-Object { $_.Current.ClassName -match '\bside-item\b' })
}

function Get-Side([string]$Pattern) { Get-SideButtons | Where-Object { $_.Current.Name -match $Pattern } | Select-Object -First 1 }

function Get-MachineRows {
    @(Get-SideButtons | Where-Object {
        $c = $_.Current
        $c.Name -and $c.ClassName -notmatch 'side-home|side-add|side-skeleton|side-label|side-space' -and $c.HelpText -notmatch 'View progress|Ver avance'
    })
}

function Get-PageErrors {
    $root = Get-MainElement
    if (-not $root) { return @('no main window') }
    @($root.FindAll($script:Desc, [Windows.Automation.Condition]::TrueCondition) | ForEach-Object {
        $c = $_.Current
        if ($c.ClassName -match '\btoast error\b|\berror-notice\b|\berror-text\b' -or $c.Name -match "Couldn't|No se pudo") { if ($c.Name) { $c.Name } else { $c.ClassName } }
    } | Where-Object { $_ } | Select-Object -Unique)
}

function Check-Page([string]$Name, [string]$File) {
    $errors = Get-PageErrors
    Check "$Name shows no error" ($errors.Count -eq 0) ($errors -join ' | ')
    $app = Get-App
    $captions = if ($app) { [E2E]::Captioned([uint32]$app.Id) } else { -1 }
    Check "$Name leaves no captioned GpuVM window" ($captions -eq 0) "$captions captioned window(s)"
    $null = Show-Main
    Shot "pages-$File"
}

function Open-Page([string]$Name, [string]$File, $Button, [string[]]$Markers) {
    if (-not $Button) { Check "the sidebar has $Name" $false 'button not found'; return $null }
    $b = $Button
    Check-NoFlash "opening $Name" ({ $null = Invoke-Element $b }.GetNewClosure())
    $found = Wait-For { Find-Text (Get-MainElement) $Markers } 5
    Check "$Name opens" ([bool]$found) ("expected: " + ($Markers -join ' / '))
    Check-Page $Name $File
    $found
}

function Measure-Open([string]$Name, $Button, [string[]]$Markers) {
    if (-not $Button) { Check "$Name opens within 3 s" $false 'button not found'; return }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $null = Invoke-Element $Button
    $found = Wait-For { Find-Text (Get-MainElement) $Markers } 3
    $sw.Stop()
    Check "$Name opens within 3 s" ($found -and $sw.ElapsedMilliseconds -le 3000) "$($sw.ElapsedMilliseconds) ms"
}

function Test-HomePage {
    $root = Get-MainElement
    $stage = Find-Text $root @('Panel width', 'Ancho del panel')
    $row = Find-Text $root @('Height of the bottom row', 'Alto de la fila de abajo')
    $homeItem = Get-Side '^(Home|Inicio)$'
    $w = Get-MainRect
    $left = if ($homeItem) { [int]($homeItem.Current.BoundingRectangle.Right + 12) } else { $w.X + 260 }
    $right = if ($stage) { [int]$stage.Current.BoundingRectangle.X - 4 } else { [int]($left + ($w.X + $w.W - $left) * 0.6) }
    $bottom = if ($row) { [int]$row.Current.BoundingRectangle.Y - 4 } else { [int]($w.Y + $w.H * 0.6) }
    $top = $w.Y + 48
    $null = Show-Main
    Start-Sleep -Milliseconds 600
    $a = Get-Area $left $top ($right - $left) ($bottom - $top)
    Start-Sleep -Milliseconds 700
    $b = Get-Area $left $top ($right - $left) ($bottom - $top)
    $life = [E2EPages]::Life($a, $b)
    Check 'Home draws the machine cube' ($life[0] -ge 0.05 -or $life[1] -ge 0.005) ("{0:P1} colored, {1:P1} moving" -f $life[0], $life[1])

    $cards = @(Find-AllText $root @('Free memory for machines', 'Memoria libre para máquinas', 'Move machines', 'Mover máquinas', 'Create your first machine', 'Crea tu primera máquina'))
    $views = @(Find-Typed $root ([Windows.Automation.ControlType]::Button) '^(View|Ver) ' | Where-Object { $_.Current.ClassName -match 'home-machine' })
    Check 'Home shows its machine panel' ($cards.Count -gt 0) "$($views.Count) more machine card(s)"

    $before = (Get-MachineRows).Count
    $dialogNames = @('Create machine', 'Crear máquina')
    $getDialog = { Find-AllText (Get-MainElement) $dialogNames | Where-Object { $_.Current.ClassName -match '^dialog\b' } | Select-Object -First 1 }
    $create = Find-Typed (Get-MainElement) ([Windows.Automation.ControlType]::Button) '^(Create machine|Crear máquina)$' | Where-Object { $_.Current.ClassName -notmatch 'side-add' } | Select-Object -First 1
    if (-not $create) { $create = Get-Side '^(Create machine|Crear máquina)$' }
    $null = Invoke-Element $create
    $dialog = Wait-For $getDialog 4
    Check '"Create machine" opens the create dialog' ([bool]$dialog) ''
    if ($dialog) {
        $parts = Find-AllText $dialog @('Starting point', 'Punto de partida', 'Name and space', 'Nombre y espacio', 'Resources', 'Recursos')
        Check 'the create dialog shows its sections' (@($parts).Count -ge 2) ((@($parts) | ForEach-Object { $_.Current.Name } | Select-Object -Unique) -join ', ')
        $null = Show-Main
        Shot 'pages-home-create'
        $cancel = Find-Typed $dialog ([Windows.Automation.ControlType]::Button) '^(Cancel|Cancelar)$' | Select-Object -First 1
        $null = Invoke-Element $cancel
        $gone = Wait-For { -not (& $getDialog) } 3
        Check 'Cancel closes the create dialog' ([bool]$gone) ''
    }
    $null = Invoke-Element (Get-Side '^(Create machine|Crear máquina)$')
    if (Wait-For $getDialog 4) {
        $null = Show-Main
        [E2EPages]::Key(0x1B)
        $gone = Wait-For { -not (& $getDialog) } 3
        Check 'Escape closes the create dialog' ([bool]$gone) ''
        if (-not $gone) {
            $close = Find-Typed (& $getDialog) ([Windows.Automation.ControlType]::Button) '^(Close|Cerrar)$' | Select-Object -First 1
            $null = Invoke-Element $close
        }
    } else { Check 'the sidebar''s "Create machine" opens the create dialog' $false '' }
    Start-Sleep -Milliseconds 800
    $after = (Get-MachineRows).Count
    Check 'closing the create dialog creates nothing' ($after -eq $before) "$before machine(s) before, $after after"
}

function Test-LibraryPage {
    $tabs = @(
        @{ Tab = '^(Profiles|Perfiles)$'; Text = @('Machine recipes: resources, apps and cleanup ready to use.', 'Recetas de máquina: recursos, apps y limpieza listos para usar.') }
        @{ Tab = '^(Templates|Plantillas)$'; Text = @('Windows already installed, with its apps, to create machines in seconds.', 'Un Windows ya instalado, con sus apps, para crear máquinas en segundos.') }
        @{ Tab = '^(Shared disks|Discos compartidos)$'; Text = @('They attach to whichever machine needs them: your games or files, stored once.', 'Se conectan a la máquina que los necesite: tus juegos o archivos, una sola vez.') }
        @{ Tab = '^(Machine disks|Discos de máquinas)$'; Text = @("Each machine's disk and the ones left without a machine.", 'El disco de cada máquina y los que quedaron sin máquina.') }
        @{ Tab = '^ISOs$'; Text = @('Windows images to create machines from scratch.', 'Las imágenes de Windows para crear máquinas desde cero.') }
    )
    foreach ($x in $tabs) {
        $tab = Find-Typed (Get-MainElement) ([Windows.Automation.ControlType]::TabItem) $x.Tab | Select-Object -First 1
        $label = ($x.Tab -replace '[\^\$\(\)]', '') -replace '\|', ' / '
        if (-not $tab) { Check "Library has the $label tab" $false ''; continue }
        $name = $tab.Current.Name
        $null = Invoke-Element $tab
        $shown = Wait-For { $d = Find-Text (Get-MainElement) $x.Text; if (Test-OnScreen $d) { $d } } 3
        Check "Library ${name}: its section comes into view" ([bool]$shown) ''
        Start-Sleep -Milliseconds 400
        Check-Page "Library $name" "library-$($name -replace '\W', '-')"
    }
}

function Test-AgentsPage {
    $root = Get-MainElement
    foreach ($x in @(@('Connected agents', 'Agentes conectados'), @('Deliveries', 'Entregas'), @('History', 'Historial'))) {
        Check "Agents shows the $($x[0]) section" ([bool](Find-Text $root $x)) ''
    }
    $history = Find-Text $root @('Which agents used your machines, when and what they did.', 'Qué agentes usaron tus máquinas, cuándo y qué hicieron.')
    Check 'Agents explains the history' ([bool]$history) ''
    $texts = Get-Texts $root
    Check 'Agents lists the connected clients or says none is connected' ($texts -match 'E2e' -or $texts -match 'No agent connected|Ningún agente conectado') ''
    $connect = Wait-For {
        $r = Get-MainElement
        $t = Find-Text $r @('Claude Code', 'Connected to Claude Code', 'Conectado a Claude Code', 'Claude Code asks before each action', 'Claude Code pide permiso en cada acción')
        if ($t) { $t } else { Find-Typed $r ([Windows.Automation.ControlType]::Text) '^claude mcp add ' | Select-Object -First 1 }
    } 6
    Check 'Agents has the Connect Claude Code area' ([bool]$connect) $(if ($connect) { $connect.Current.Name } else { '' })
}

function Test-ThemeChange {
    $root = Get-MainElement
    $radios = Find-Typed $root ([Windows.Automation.ControlType]::RadioButton)
    $system = $radios | Where-Object { $_.Current.Name -match '^(System|Sistema)$' } | Select-Object -First 1
    $light = $radios | Where-Object { $_.Current.Name -match '^(Light|Claro)$' } | Select-Object -First 1
    $dark = $radios | Where-Object { $_.Current.Name -match '^(Dark|Oscuro)$' } | Select-Object -First 1
    $orig = @($system, $light, $dark) | Where-Object { $_ -and (Test-Selected $_) } | Select-Object -First 1
    Check 'Appearance shows the theme choice (System, Light, Dark) with one selected' ($system -and $light -and $dark -and $orig) $(if ($orig) { "selected: $($orig.Current.Name)" } else { '' })
    if (-not ($light -and $dark -and $orig)) { return }

    $null = Show-Main
    Start-Sleep -Milliseconds 300
    $t0 = Get-WindowTones
    $toDark = $t0[1] -ge $t0[0]
    $target = if ($toDark) { $dark } else { $light }
    $targetName = $target.Current.Name
    try {
        Check-NoFlash "switching the theme to $targetName" ({ $null = Invoke-Element $target }.GetNewClosure()) -PictureChanges
        $picked = Test-Selected $target
        if (-not $picked) { $picked = Select-Option $target }
        Start-Sleep -Milliseconds 800
        $null = Show-Main
        $t1 = Get-WindowTones
        $delta = if ($toDark) { $t1[0] - $t0[0] } else { $t1[1] - $t0[1] }
        Check "theme $targetName changes the app's colors on screen" ($picked -and $delta -ge 0.15) ("dark {0:P0} -> {1:P0}, light {2:P0} -> {3:P0}" -f $t0[0], $t1[0], $t0[1], $t1[1])
        Shot "pages-settings-theme-$($targetName -replace '\W', '-')"
    }
    finally {
        $back = Select-Option $orig
        Start-Sleep -Milliseconds 800
        $null = Show-Main
        $t2 = Get-WindowTones
        Check "the theme goes back to $($orig.Current.Name)" ($back -and [Math]::Abs($t2[1] - $t0[1]) -lt 0.12 -and [Math]::Abs($t2[0] - $t0[0]) -lt 0.12) ("light {0:P0} at first, {1:P0} now" -f $t0[1], $t2[1])
    }
}

function Test-PlacementEditor {
    $pieces = @(Find-AllText (Get-MainElement) @('Requests', 'Solicitudes', 'Status notices', 'Avisos de estado') | Where-Object { $_.Current.ClassName -match '\bpl-piece\b' })
    if (-not $pieces.Count) { Check 'the notch and dock placement editor is there' $false 'no pieces found'; return }
    $onScreen = 0
    foreach ($piece in $pieces) {
        $p = $null
        if ($piece.TryGetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern, [ref]$p)) { try { $p.ScrollIntoView() } catch { } }
        Start-Sleep -Milliseconds 700
        $null = Show-Main
        if (-not (Test-OnScreen $piece)) { continue }
        $onScreen++
        $r = $piece.Current.BoundingRectangle
        if ($r.Width -lt 16 -or $r.Height -lt 10) { continue }
        $t = [E2E]::Tones((Get-Area ([int]$r.X + 4) ([int]$r.Y + 3) ([int]$r.Width - 8) ([int]$r.Height - 6)))
        Check "placement piece '$($piece.Current.Name)' is drawn" ($t[0] -ge 0.45) ("dark {0:P0}" -f $t[0])
    }
    Check 'the placement editor shows the notch and the dock' ($pieces.Count -ge 2 -and $onScreen -ge 2) "$($pieces.Count) piece(s), $onScreen brought on screen"
    $rs = @($pieces | ForEach-Object { $_.Current.BoundingRectangle })
    $x0 = [int](($rs | ForEach-Object { $_.X } | Measure-Object -Minimum).Minimum)
    $y0 = [int](($rs | ForEach-Object { $_.Y } | Measure-Object -Minimum).Minimum)
    $x1 = [int](($rs | ForEach-Object { $_.X + $_.Width } | Measure-Object -Maximum).Maximum)
    $y1 = [int](($rs | ForEach-Object { $_.Y + $_.Height } | Measure-Object -Maximum).Maximum)
    if ($x1 - $x0 -gt 20 -and $y1 - $y0 -gt 10) {
        $t = [E2E]::Tones((Get-Area $x0 $y0 ($x1 - $x0) ($y1 - $y0)))
        Check 'the placement editor draws a desktop behind the pieces' ($t[1] -lt 0.6) ("light {0:P0}" -f $t[1])
        $bmp = Grab ([Math]::Max(0, $x0 - 40)) ([Math]::Max(0, $y0 - 40)) ($x1 - $x0 + 80) ($y1 - $y0 + 80)
        $bmp.Save((Join-Path $Ctx.Out 'pages-settings-placement.png')); $bmp.Dispose()
    }
}

function Test-SettingsPage {
    $sections = @(
        @{ Tab = '^(Appearance|Apariencia)$'; Text = @('Theme', 'Tema', 'Language', 'Idioma', 'Accent color', 'Color de énfasis', 'Animation smoothness', 'Fluidez de las animaciones') }
        @{ Tab = '^(Window|Ventana)$'; Text = @('When closing the window', 'Al cerrar la ventana', 'When quitting GpuVM', 'Al salir de GpuVM', 'Going back to Home from a machine', 'Al volver a Inicio desde una máquina') }
        @{ Tab = '^(Machines|Máquinas)$'; Text = @('Open machines on', 'Abrir las máquinas en'); Optional = $true }
        @{ Tab = '^(Agents|Agentes)$'; Text = @('Take control', 'Tomar el control', 'Time to answer', 'Tiempo para responder', 'Session limit', 'Límite por sesión') }
        @{ Tab = '^(Captures|Capturas)$'; Text = @('Save the last 30 s', 'Guardar los últimos 30 s', 'Screenshots folder', 'Carpeta de capturas', 'Videos folder', 'Carpeta de videos') }
        @{ Tab = '^(Service|Servicio)$'; Text = @('GpuVM service', 'Servicio de GpuVM', 'Status', 'Estado') }
    )
    $nav = Find-Text (Get-MainElement) @('Settings sections', 'Secciones de Ajustes')
    Check 'Settings shows its section list' ([bool]$nav) ''
    if (-not $nav) { return }
    foreach ($x in $sections) {
        $tab = Find-Typed $nav ([Windows.Automation.ControlType]::TabItem) $x.Tab | Select-Object -First 1
        $label = ($x.Tab -replace '[\^\$\(\)]', '') -replace '\|', ' / '
        if (-not $tab) {
            if ($x.Optional) { Write-Host "  (no $label section: one monitor)" } else { Check "Settings has the $label section" $false '' }
            continue
        }
        $name = $tab.Current.Name
        $picked = Select-Option $tab
        $want = [Math]::Ceiling($x.Text.Count / 2)
        $seen = Wait-For {
            $r = Get-MainElement
            $n = @(Find-AllText $r $x.Text | ForEach-Object { $_.Current.Name } | Select-Object -Unique).Count
            if ($n -ge $want) { $n }
        } 3
        Check "Settings ${name}: the section opens with its options" ($picked -and $seen) "$([int]$seen) of $want options found"
        $root = Get-MainElement
        $preview = Find-Text $root @('Preview', 'Vista previa')
        $pr = if ($preview) { $preview.Current.BoundingRectangle } else { $null }
        $controls = @(@([Windows.Automation.ControlType]::RadioButton, [Windows.Automation.ControlType]::Slider, [Windows.Automation.ControlType]::Button, [Windows.Automation.ControlType]::ComboBox, [Windows.Automation.ControlType]::CheckBox) | ForEach-Object { Find-Typed $root $_ } | Where-Object {
            $c = $_.Current; $r = $c.BoundingRectangle
            $c.ClassName -notmatch 'side-item|side-handle|pref-nav-item|swatch' -and -not ($pr -and $r.X -ge $pr.X - 1 -and $r.X -le $pr.X + $pr.Width)
        })
        Check "Settings ${name}: shows its controls" ($controls.Count -ge 1) "$($controls.Count) control(s)"
        Check-Page "Settings $name" "settings-$($name -replace '\W', '-')"
        if ($x.Tab -match 'Appearance') {
            Test-ThemeChange
            Test-PlacementEditor
        }
    }
}

function Test-MachinePage([string]$Name) {
    $root = Get-MainElement
    $stats = @(Find-AllText $root @('Processor', 'Procesador', 'Memory', 'Memoria', 'GPU', 'Uptime', 'Tiempo encendida') | ForEach-Object { $_.Current.Name } | Select-Object -Unique)
    Check "${Name}: shows its resources" ($stats.Count -ge 4) ($stats -join ', ')
    $tabs = @(Find-Typed $root ([Windows.Automation.ControlType]::TabItem))
    $tabNames = @($tabs | ForEach-Object { $_.Current.Name })
    $managed = $tabNames -match '^(Machine|Máquina)$'
    $points = Find-Text $root @('Restore points', 'Puntos de restauración')
    if ($managed) { Check "${Name}: shows its restore points" ([bool]$points) '' }
    else { Write-Host "  ($Name is not managed by GpuVM: no restore points)" }
    if ($tabNames -match '^(Agent|Agente)$') {
        $hist = Find-Text $root @('History', 'Historial')
        Check "${Name}: shows its agent history" ([bool]$hist) ''
    }
    foreach ($tab in $tabs) {
        $tn = $tab.Current.Name
        $null = Invoke-Element $tab
        Start-Sleep -Milliseconds 900
        $mark = switch -Regex ($tn) {
            '^(Machine|Máquina)$' { @('GPU for the VM', 'GPU para la VM') }
            '^(Agent|Agente)$' { @('History', 'Historial') }
            default { $null }
        }
        if ($mark) {
            $shown = Wait-For { $d = Find-Text (Get-MainElement) $mark; if (Test-OnScreen $d) { $d } } 3
            Check "${Name} ${tn}: its section comes into view" ([bool]$shown) ''
        }
        Check-Page "$Name $tn" "machine-$($tn -replace '\W', '-')"
    }
}

function Test-Suite($Ctx) {
    $null = Show-Main
    $ready = Wait-For { Get-Side '^(Settings|Ajustes)$' } 10
    Check 'the main window shows the sidebar' ([bool]$ready) ''
    if (-not $ready) { return }
    Check 'no captioned GpuVM window at the start' ([E2E]::Captioned([uint32](Get-App).Id) -eq 0) ''

    $homeMarks = @('Free memory for machines', 'Memoria libre para máquinas', 'Move machines', 'Mover máquinas', 'Create your first machine', 'Crea tu primera máquina')
    $libMarks = @('Machine recipes: resources, apps and cleanup ready to use.', 'Recetas de máquina: recursos, apps y limpieza listos para usar.')
    $agentMarks = @('Connected agents', 'Agentes conectados')
    $prefMarks = @('Settings sections', 'Secciones de Ajustes')
    $vmMarks = @('Uptime', 'Tiempo encendida')

    if (Open-Page 'Home' 'home' (Get-Side '^(Home|Inicio)$') $homeMarks) { Test-HomePage }
    if (Open-Page 'Library' 'library' (Get-Side '^(Library|Biblioteca)$') $libMarks) { Test-LibraryPage }
    if (Open-Page 'Agents' 'agents' (Get-Side '^(Agents|Agentes)\b') $agentMarks) { Test-AgentsPage }
    if (Open-Page 'Settings' 'settings' (Get-Side '^(Settings|Ajustes)$') $prefMarks) { Test-SettingsPage }

    $rows = @(Get-MachineRows)
    Write-Host "  $($rows.Count) machine(s) in the sidebar"
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $row = @(Get-MachineRows)[$i]
        if (-not $row) { break }
        $name = $row.Current.Name
        $file = "machine-$i-$($name -replace '\W', '-')"
        if (-not (Open-Page "machine $name" $file $row $vmMarks)) { continue }
        $active = Wait-For { $r = @(Get-MachineRows)[$i]; $r -and $r.Current.ClassName -match '\bactive\b' } 3
        Check "machine ${name}: its sidebar row is selected" ([bool]$active) ''
        if ($i -eq 0) { Test-MachinePage $name }
    }

    Measure-Open 'Home' (Get-Side '^(Home|Inicio)$') $homeMarks
    Measure-Open 'Library' (Get-Side '^(Library|Biblioteca)$') $libMarks
    Measure-Open 'Agents' (Get-Side '^(Agents|Agentes)\b') $agentMarks
    Measure-Open 'Settings' (Get-Side '^(Settings|Ajustes)$') $prefMarks
    $first = @(Get-MachineRows) | Select-Object -First 1
    if ($first) { Measure-Open "machine $($first.Current.Name)" $first $vmMarks }
    Measure-Open 'Home again' (Get-Side '^(Home|Inicio)$') $homeMarks

    $app = Get-App
    Check 'the app still responds' ($app -and $app.Responding) ''
    Check 'no captioned GpuVM window at the end' ($app -and [E2E]::Captioned([uint32]$app.Id) -eq 0) ''
}
