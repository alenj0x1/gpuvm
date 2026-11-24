# Settings that change what the person sees (language, accent, notice placement, Home disconnect, time to answer,
# the last 30 s), the title bar, spaces, profiles, shared disks and a game, each setting read first and put back.
if (-not ('E2ESL' -as [type])) {
    Add-Type @'
using System; using System.Runtime.InteropServices;
public static class E2ESL {
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint f, IntPtr e);
  public static bool Front(IntPtr h) {
    if (GetForegroundWindow() == h) return true;
    if (IsIconic(h)) ShowWindow(h, 9);
    keybd_event(0x12, 0, 0, IntPtr.Zero); keybd_event(0x12, 0, 2, IntPtr.Zero);
    SetForegroundWindow(h); System.Threading.Thread.Sleep(250);
    return GetForegroundWindow() == h;
  }
  public static void Key(byte vk) { keybd_event(vk, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(40); keybd_event(vk, 0, 2, IntPtr.Zero); System.Threading.Thread.Sleep(60); }
  public static void Drag(int x0, int y0, int x1, int y1) {
    SetCursorPos(x0, y0); System.Threading.Thread.Sleep(150);
    mouse_event(2, 0, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(100);
    for (int i = 1; i <= 24; i++) { SetCursorPos(x0 + (x1 - x0) * i / 24, y0 + (y1 - y0) * i / 24); System.Threading.Thread.Sleep(20); }
    System.Threading.Thread.Sleep(150); mouse_event(4, 0, 0, 0, IntPtr.Zero);
  }
  // BGRA bytes: hue in degrees of the mean color of the saturated pixels, and how many there were.
  public static double[] Hue(byte[] p) {
    long r = 0, g = 0, b = 0; int n = 0;
    for (int i = 0; i + 3 < p.Length; i += 4) {
      int B = p[i], G = p[i+1], R = p[i+2], mx = Math.Max(R, Math.Max(G, B)), mn = Math.Min(R, Math.Min(G, B));
      if (mx - mn > 50) { r += R; g += G; b += B; n++; }
    }
    if (n == 0) return new double[] { -1, 0 };
    double rr = (double)r / n, gg = (double)g / n, bb = (double)b / n;
    double M = Math.Max(rr, Math.Max(gg, bb)), m = Math.Min(rr, Math.Min(gg, bb)), d = M - m, h;
    if (d < 1e-6) h = 0; else if (M == rr) h = 60 * (((gg - bb) / d) % 6); else if (M == gg) h = 60 * ((bb - rr) / d + 2); else h = 60 * ((rr - gg) / d + 4);
    if (h < 0) h += 360;
    return new double[] { h, n };
  }
}
'@
}

function Get-SlLabel([string]$Pattern) { (($Pattern -replace '\\s\*', '') -replace '[\^\$\(\)]', '') -replace '\|', ' / ' }

function Get-SlType([string]$Name) { [Windows.Automation.ControlType]::$Name }

function Find-SlAll($Root, [string]$Type = '', [string]$Pattern = '', [string]$Class = '') {
    if (-not $Root) { return @() }
    $card = $Root.PSObject.Properties.Name -contains 'Card'
    $from = if ($card) { $Root.Root } else { $Root }
    $cond = if ($Type) { [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, (Get-SlType $Type)) } else { [Windows.Automation.Condition]::TrueCondition }
    try {
        @($from.FindAll([Windows.Automation.TreeScope]::Descendants, $cond) | Where-Object {
            $c = $_.Current; $r = $c.BoundingRectangle
            $c.Name -match $Pattern -and (-not $Class -or $c.ClassName -match $Class) -and
                (-not $card -or ($r.Width -gt 0 -and $r.X + $r.Width / 2 -ge $Root.X -and $r.X + $r.Width / 2 -le $Root.X + $Root.W -and $r.Y + $r.Height / 2 -ge $Root.Y -and $r.Y + $r.Height / 2 -le $Root.Y + $Root.H))
        })
    } catch { @() }
}

function Find-SlOne($Root, [string]$Type = '', [string]$Pattern = '', [string]$Class = '') { Find-SlAll $Root $Type $Pattern $Class | Select-Object -First 1 }

function Show-SlMain { $app = Get-App; if ($app) { [E2ESL]::Front($app.MainWindowHandle) } else { $false } }

function Test-SlOn($El) {
    if (-not $El) { return $false }
    try { if ($El.Current.ClassName -match '\bon\b') { return $true } } catch { return $false }
    $p = $null
    try { if ($El.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { return $p.Current.IsSelected } } catch { }
    $false
}

# A real click on the element; when something else is over it, it is invoked instead and the result says so.
function Press-SlReal($El) {
    if (-not $El) { return $false }
    $p = $null
    try { if ($El.TryGetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern, [ref]$p)) { $p.ScrollIntoView(); Start-Sleep -Milliseconds 250 } } catch { }
    $null = Show-SlMain
    if (Click-Element $El) { return $true }
    try { $null = Invoke-Element $El } catch { }
    $false
}

function Get-SlRadio([string]$Pattern) { Find-SlOne (Get-MainElement) 'RadioButton' $Pattern }

function Read-SlRadio([string[]]$Patterns) {
    foreach ($x in $Patterns) { if (Test-SlOn (Get-SlRadio $x)) { return $x } }
    $null
}

function Select-SlRadio([string]$Pattern) {
    if (-not $Pattern) { return $false }
    $r = Wait-For { Get-SlRadio $Pattern } 3
    if (-not $r) { return $false }
    if (Test-SlOn $r) { return $true }
    $null = Press-SlReal $r
    [bool](Wait-For { Test-SlOn (Get-SlRadio $Pattern) } 3)
}

function Get-SlSideNames { @(Find-SlAll (Get-MainElement) 'Button' '' '\bside-item\b' | ForEach-Object { $_.Current.Name.Trim() }) }

function Get-SlSide([string]$Pattern) { Find-SlOne (Get-MainElement) 'Button' $Pattern '\bside-item\b' }

function Exit-SlViewer {
    $back = Find-SlOne (Get-MainElement) '' '' '\btitlebar-back\b'
    if ($back) {
        $null = Wait-For { $b = Find-SlOne (Get-MainElement) '' '' '\btitlebar-back\b'; -not $b -or $b.Current.IsEnabled } 15
        try { $null = Invoke-Element $back } catch { }
        $null = Wait-For { -not (Find-SlOne (Get-MainElement) '' '' '\btitlebar-back\b') } 10
    }
    $null = Show-SlMain
}

function Open-SlSide([string]$Pattern) {
    Exit-SlViewer
    $side = Wait-For { Get-SlSide $Pattern } 5
    if (-not $side) { return $false }
    $null = Press-SlReal $side
    [bool](Wait-For { $s = Get-SlSide $Pattern; $s -and $s.Current.ClassName -match '\bactive\b' } 5)
}

function Open-SlSettings([string]$Tab) {
    if (-not (Open-SlSide '^(Settings|Ajustes)$')) { return $false }
    $t = Wait-For { Find-SlOne (Get-MainElement) 'TabItem' $Tab '\bpref-nav-item\b' } 5
    if (-not $t) { return $false }
    if ($t.Current.ClassName -notmatch '\bon\b') { $null = Press-SlReal $t }
    [bool](Wait-For { $x = Find-SlOne (Get-MainElement) 'TabItem' $Tab '\bpref-nav-item\b'; $x -and $x.Current.ClassName -match '\bon\b' } 3)
}

function Open-SlLibraryTab([string]$Tab) {
    if (-not (Open-SlSide '^(Library|Biblioteca)$')) { return $false }
    $t = Wait-For { Find-SlOne (Get-MainElement) 'TabItem' $Tab } 5
    if (-not $t) { return $false }
    $null = Press-SlReal $t
    Start-Sleep -Milliseconds 700
    $true
}

function Get-SlDialog([string]$Pattern) { Find-SlOne (Get-MainElement) '' $Pattern '^dialog\b' }

function Close-SlDialogs {
    for ($i = 0; $i -lt 3 -and (Find-SlOne (Get-MainElement) '' '' '^dialog\b'); $i++) { $null = Show-SlMain; [E2ESL]::Key(0x1B); Start-Sleep -Milliseconds 400 }
}

function Set-SlText($El, [string]$Text) {
    if (-not $El) { return $false }
    $null = Press-SlReal $El
    Start-Sleep -Milliseconds 150
    [Windows.Forms.SendKeys]::SendWait('^a'); [Windows.Forms.SendKeys]::SendWait('{BACKSPACE}')
    [Windows.Forms.SendKeys]::SendWait(($Text -replace '([+^%~(){}\[\]])', '{$1}'))
    Start-Sleep -Milliseconds 250
    $p = $null
    if ($El.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$p)) { return $p.Current.Value -eq $Text }
    $true
}

function Get-SlValue($El) {
    $p = $null
    if ($El -and $El.TryGetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern, [ref]$p)) { return [int]$p.Current.Value }
    -1
}

# A real click at the slider's left end, then Home: its minimum.
function Set-SlSliderMin($El) {
    if (-not $El) { return $false }
    $p = $null
    try { if ($El.TryGetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern, [ref]$p)) { $p.ScrollIntoView(); Start-Sleep -Milliseconds 250 } } catch { }
    $null = Show-SlMain
    $r = $El.Current.BoundingRectangle
    $x = [int]$r.X + 2; $y = [int]($r.Y + 10)
    if ([E2E]::ProcessNameAt($x, $y) -eq 'gpuvm') { [E2E]::Click($x, $y) } else { try { $El.SetFocus() } catch { } }
    [E2ESL]::Key(0x24)
    $true
}

function Set-SlSliderIndex($El, [int]$Index) {
    if (-not $El -or $Index -lt 0) { return $false }
    try { $El.SetFocus() } catch { }
    $null = Show-SlMain
    try { $El.SetFocus() } catch { }
    for ($try = 0; $try -lt 2; $try++) {
        # Second try: a viewer or dock may have kept the keyboard; a click on the slider gives it the focus.
        if ($try) { $null = Show-SlMain; $null = Click-Element $El; Start-Sleep -Milliseconds 300 }
        [E2ESL]::Key(0x24)
        for ($i = 0; $i -lt $Index; $i++) { [E2ESL]::Key(0x27) }
        Start-Sleep -Milliseconds 900
        if ((Get-SlValue $El) -eq $Index) { return $true }
    }
    $false
}

# A Library card's box isn't in UI Automation (a plain div): the card is the area from its name down to its buttons.
# Profiles and shared disks get the same e2e name: the card is looked for between its section's heading and the next.
$script:SlSections = @{
    Profiles = @('^(Profiles|Perfiles)$', '^(Templates|Plantillas)$')
    Disks    = @('^(Shared disks|Discos compartidos)$', '^(Machine disks|Discos de m.quinas)$')
}

function Get-SlCard([string]$Name, [string]$Section = 'Profiles') {
    $main = Get-MainElement
    # Section headings are taller than the same words in the drive usage legend above them.
    $from = Find-SlAll $main 'Text' $script:SlSections[$Section][0] | Where-Object { $_.Current.BoundingRectangle.Height -ge 18 } | Select-Object -First 1
    $top = if ($from) { $from.Current.BoundingRectangle.Y } else { [double]::MinValue }
    $to = Find-SlAll $main 'Text' $script:SlSections[$Section][1] | Where-Object { $_.Current.BoundingRectangle.Height -ge 18 -and $_.Current.BoundingRectangle.Y -gt $top } | Select-Object -First 1
    $bottom = if ($to) { $to.Current.BoundingRectangle.Y } else { [double]::MaxValue }
    $left = if ($from) { $from.Current.BoundingRectangle.X - 60 } else { [double]::MinValue }
    # A space of the same name shows in the sidebar, left of the section.
    $t = Find-SlAll $main 'Text' "^$([regex]::Escape($Name))$" | Where-Object { $r = $_.Current.BoundingRectangle; $r.Y -gt $top -and $r.Y -lt $bottom -and $r.X -ge $left } | Select-Object -First 1
    if (-not $t) { return $null }
    $r = $t.Current.BoundingRectangle
    [pscustomobject]@{ Card = $Name; Root = (Get-MainElement); X = $r.X - 16; Y = $r.Y - 10; W = 316; H = 230 }
}

function Get-SlCardTexts($Card) { (Find-SlAll $Card | ForEach-Object { $_.Current.Name } | Where-Object { $_ }) -join ' | ' }

function Get-SlViewer {
    Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
        Sort-Object { $r = [E2E]::Rect($_.MainWindowHandle); - [long]$r[2] * $r[3] } | Select-Object -First 1
}

function Focus-SlViewer { $v = Wait-For { Get-SlViewer } 10; if ($v) { $null = [E2ESL]::Front($v.MainWindowHandle); Start-Sleep -Milliseconds 300 }; $v }

function Wait-SlReply($Session, [int]$Id, [double]$Seconds) {
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

function Get-SlText($Reply) { if ($null -eq $Reply) { '(no answer in time)' } elseif ($Reply.error) { "JSON-RPC error: $($Reply.error.message)" } else { Text-Of $Reply } }

function Invoke-SlCall($Session, [string]$Name, [hashtable]$Arguments, [double]$Seconds = 60) { Get-SlText (Wait-SlReply $Session (Start-Tool $Session $Name $Arguments) $Seconds) }

function Find-SlDock([string]$Pattern) {
    $app = Get-App
    $main = if ($app) { $app.MainWindowHandle } else { [IntPtr]::Zero }
    foreach ($w in Get-AppWindows) {
        if ($w.Handle -eq $main) { continue }
        try { $root = Get-Element $w.Handle; $texts = Get-Texts $root; if ($texts -match $Pattern) { return [pscustomobject]@{ Root = $root; Texts = $texts } } } catch { }
    }
    $null
}

function Step-Sl([string]$Name, [scriptblock]$Body) {
    try { & $Body } catch { Check "$Name ran to the end" $false $_.Exception.Message }
    try { Close-SlDialogs } catch { }
}

# ---------- the checks

function Test-SlLanguage {
    if (-not (Open-SlSettings '^(Appearance|Apariencia)$')) { Check 'Settings > Appearance opens' $false ''; return }
    $orig = Read-SlRadio @('^\s*Windows\s*$', '^\s*Español\s*$', '^\s*English\s*$')
    Check 'the language choice is readable' ([bool]$orig) "selected: $orig"
    if (-not $orig) { return }
    $spanishNow = (Get-SlSideNames) -contains 'Inicio'
    $target = if ($spanishNow) { '^\s*English\s*$' } else { '^\s*Español\s*$' }
    $want = if ($spanishNow) { @('Home', 'Library', 'Settings') } else { @('Inicio', 'Biblioteca', 'Ajustes') }
    $label = Get-SlLabel $target
    try {
        $picked = Select-SlRadio $target
        $ok = Wait-For { $n = Get-SlSideNames; @($want | Where-Object { $n -contains $_ }).Count -eq 3 } 6
        Check "Language ${label}: the sidebar reads $($want -join ', ')" ($picked -and [bool]$ok) ((Get-SlSideNames | Select-Object -First 4) -join ', ')
        Shot 'settings-language'
    }
    finally {
        $back = Select-SlRadio $orig
        $first = if ($spanishNow) { 'Inicio' } else { 'Home' }
        $ok = Wait-For { (Get-SlSideNames) -contains $first } 6
        Check "the language goes back to $(Get-SlLabel $orig)" ($back -and [bool]$ok) ((Get-SlSideNames | Select-Object -First 4) -join ', ')
    }
}

# The primary button is gray in every accent (--btn-bg); the accent shows on sliders, so one of them is measured.
function Get-SlAccentHue {
    $s = Find-SlOne (Get-MainElement) 'Slider' '^(Animation smoothness|Fluidez de las animaciones)$'
    if (-not $s) { return , @(-1.0, 0.0) }
    $p = $null
    try { if ($s.TryGetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern, [ref]$p)) { $p.ScrollIntoView() } } catch { }
    $null = Show-SlMain
    Start-Sleep -Milliseconds 500
    $r = $s.Current.BoundingRectangle
    $bmp = Grab ([int]$r.X - 10) ([int]$r.Y) ([int]$r.Width + 20) ([int][Math]::Max(8, [Math]::Min($r.Height, 26)))
    $h = [E2ESL]::Hue((Bytes $bmp)); $bmp.Dispose()
    , $h
}

function Get-SlHueGap([double]$A, [double]$B) { $d = [Math]::Abs($A - $B) % 360; [Math]::Min($d, 360 - $d) }

function Test-SlAccent {
    if (-not (Open-SlSettings '^(Appearance|Apariencia)$')) { Check 'Settings > Appearance opens' $false ''; return }
    $swatches = @(Find-SlAll (Get-MainElement) 'RadioButton' '' '\bswatch\b')
    $origIndex = -1
    for ($i = 0; $i -lt $swatches.Count; $i++) { if (Test-SlOn $swatches[$i]) { $origIndex = $i } }
    Check 'the accent swatches show with one selected' ($swatches.Count -ge 2 -and $origIndex -ge 0) "$($swatches.Count) swatch(es), selected #$origIndex"
    if ($origIndex -lt 0) { return }
    $targetIndex = if ($origIndex -eq $swatches.Count - 1) { 0 } else { $swatches.Count - 1 }
    $origName = $swatches[$origIndex].Current.Name
    $h0 = Get-SlAccentHue
    try {
        $null = Press-SlReal $swatches[$targetIndex]
        $on = Wait-For { $x = @(Find-SlAll (Get-MainElement) 'RadioButton' '' '\bswatch\b'); $x.Count -gt $targetIndex -and (Test-SlOn $x[$targetIndex]) } 3
        Start-Sleep -Milliseconds 600
        $h1 = Get-SlAccentHue
        $gap = Get-SlHueGap $h0[0] $h1[0]
        Check "accent $($swatches[$targetIndex].Current.Name): the accent on screen changes hue" ([bool]$on -and $h0[1] -gt 15 -and $h1[1] -gt 15 -and $gap -ge 25) ("hue {0:N0} -> {1:N0} ({2:N0} and {3:N0} colored px)" -f $h0[0], $h1[0], $h0[1], $h1[1])
        Shot 'settings-accent'
    }
    finally {
        $x = @(Find-SlAll (Get-MainElement) 'RadioButton' '' '\bswatch\b')
        if ($x.Count -gt $origIndex) { $null = Press-SlReal $x[$origIndex] }
        Start-Sleep -Milliseconds 600
        $h2 = Get-SlAccentHue
        $x = @(Find-SlAll (Get-MainElement) 'RadioButton' '' '\bswatch\b')
        Check "the accent goes back to $origName" ($x.Count -gt $origIndex -and (Test-SlOn $x[$origIndex]) -and (Get-SlHueGap $h0[0] $h2[0]) -lt 15) ("hue {0:N0} at first, {1:N0} now" -f $h0[0], $h2[0])
    }
}

function Get-SlPiece { Find-SlOne (Get-MainElement) '' '^(Status notices|Avisos de estado)$' '\bpl-piece\b' }
# The stage is a nameless group outside UI Automation's control view: it is reached as the piece's parent.
function Get-SlStage { $p = Get-SlPiece; if ($p) { $s = [Windows.Automation.TreeWalker]::RawViewWalker.GetParent($p); if ($s -and $s.Current.ClassName -match '\bpl-stage\b') { $s } } }

# Drags the notch piece by $Dy pixels; returns its offset from the preview's top afterwards.
function Move-SlPiece([int]$Dy) {
    $piece = Get-SlPiece
    if (-not $piece) { return $null }
    $p = $null
    try { if ($piece.TryGetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern, [ref]$p)) { $p.ScrollIntoView(); Start-Sleep -Milliseconds 300 } } catch { }
    $null = Show-SlMain
    $r = (Get-SlPiece).Current.BoundingRectangle
    $x = [int]($r.X + $r.Width / 2); $y = [int]($r.Y + $r.Height / 2)
    if ([E2E]::ProcessNameAt($x, $y) -ne 'gpuvm') { Write-Host "     drag refused: $([E2E]::ProcessNameAt($x, $y)) is over the notch piece"; return $null }
    [E2ESL]::Drag($x, $y, $x, $y + $Dy)
    Start-Sleep -Milliseconds 700
    Get-SlPieceOffset
}

function Get-SlPieceOffset { $p = Get-SlPiece; $s = Get-SlStage; if ($p -and $s) { [int]($p.Current.BoundingRectangle.Y - $s.Current.BoundingRectangle.Y) } else { $null } }

function Test-SlNotchPlacement($Ctx, [string]$Tag) {
    $appearance = '^(Appearance|Apariencia)$'
    $pictureRe = '^(Notices over the picture|Avisos sobre la imagen)$'
    $panelRe = '^(Only in the side panel|Solo en el panel lateral)$'
    if (-not (Open-SlSettings $appearance)) { Check 'Settings > Appearance opens' $false ''; return }
    $orig = Read-SlRadio @($pictureRe, $panelRe)
    Check 'the notice placement is readable' ([bool]$orig) "selected: $orig"
    if (-not $orig) { return }
    $wasDefault = -not (Find-SlOne (Get-MainElement) 'Button' '^(Recommended places|Lugares recomendados)$')
    # A place the person chose can't be put back exactly by dragging (each run left it a few pixels higher): the drag
    # is only tried from the recommended places, which one click restores.
    if (-not $wasDefault) { Write-Host '     INFO  notch placement: the notices are where the person put them; not moved'; return }
    $origOffset = $null; $moved = $false
    try {
        $null = Select-SlRadio $pictureRe
        $origOffset = Wait-For { Get-SlPieceOffset } 3
        if ($null -eq $origOffset) { Check 'the placement preview shows the status notices piece' $false ''; return }
        $now = Move-SlPiece (-$origOffset - 6)
        $moved = $null -ne $now -and $now -ne $origOffset
        Check 'status notices: dragged to the top of the placement preview' ($null -ne $now -and $now -le 2) "offset from the top: $origOffset -> $now px"

        $vm = Use-Machine $Ctx
        $intent = "Notch on top $Tag"
        $id = Start-Tool $Ctx.Mcp 'run' @{ machine = $vm; command = 'Start-Sleep -Seconds 6'; intent = $intent }
        $n = Wait-Notch ([regex]::Escape($intent)) 8
        $v = Get-SlViewer
        $pic = if ($v) { [E2E]::Rect($v.MainWindowHandle) } else { $null }
        $ok = $n -and $pic -and ($n.Y + $n.H / 2) -lt ($pic[1] + $pic[3] / 3)
        Check 'status notices at the top: the agent''s notch shows in the top third of the picture' ([bool]$ok) $(if ($n -and $pic) { "notch y $($n.Y)+$($n.H), picture y $($pic[1])+$($pic[3])" } else { "notch: $([bool]$n), viewer: $([bool]$pic)" })
        Shot 'settings-notch-top'
        $null = Wait-SlReply $Ctx.Mcp $id 30

        if (-not (Open-SlSettings $appearance)) { throw 'Settings > Appearance did not open again.' }
        if ($moved) {
            if ($wasDefault) { $null = Press-SlReal (Find-SlOne (Get-MainElement) 'Button' '^(Recommended places|Lugares recomendados)$'); Start-Sleep -Milliseconds 600 }
            else { $cur = Get-SlPieceOffset; if ($null -ne $cur) { $null = Move-SlPiece ($origOffset - $cur) } }
            $back = Get-SlPieceOffset
            # Back at the recommended places when that button is gone again (the preview can still be settling when its
            # first offset is read).
            $moved = [bool](Wait-For { Find-SlOne (Get-MainElement) 'Button' '^(Recommended places|Lugares recomendados)$' } 1)
            Check 'the status notices piece goes back to its place' (-not $moved) "offset $back px, was $origOffset px; recommended places: $(-not $moved)"
        }

        $panel = Select-SlRadio $panelRe
        Check '"Only in the side panel" is selected' $panel ''
        $vm = Use-Machine $Ctx
        $intent = "Panel only $Tag"
        $id = Start-Tool $Ctx.Mcp 'run' @{ machine = $vm; command = 'Start-Sleep -Seconds 6'; intent = $intent }
        $seen = $null
        $deadline = (Get-Date).AddSeconds(7)
        while (-not $seen -and (Get-Date) -lt $deadline) { $seen = Get-Notch; Start-Sleep -Milliseconds 300 }
        Check '"Only in the side panel": no notch window over the picture during an agent run' (-not $seen) $(if ($seen) { "notch at $($seen.X),$($seen.Y): $($seen.Text)" } else { 'none in 7 s' })
        Shot 'settings-notch-panel'
        $null = Wait-SlReply $Ctx.Mcp $id 30
    }
    finally {
        $null = Open-SlSettings $appearance
        if ($moved -and $null -ne $origOffset) {
            $null = Select-SlRadio $pictureRe
            if ($wasDefault) { $null = Press-SlReal (Find-SlOne (Get-MainElement) 'Button' '^(Recommended places|Lugares recomendados)$') }
            else { $cur = Get-SlPieceOffset; if ($null -ne $cur) { $null = Move-SlPiece ($origOffset - $cur) } }
        }
        $back = Select-SlRadio $orig
        Check "the notice placement goes back to $(Get-SlLabel $orig)" $back ''
    }
}

function Test-SlDisconnect($Ctx) {
    $window = '^(Window|Ventana)$'
    $keepRe = '^(Keep it connected|Mantenerla conectada)$'
    $dropRe = '^(Disconnect it|Desconectarla)$'
    if (-not (Open-SlSettings $window)) { Check 'Settings > Window opens' $false ''; return }
    $orig = Read-SlRadio @($keepRe, $dropRe)
    Check 'the "going back to Home" setting is readable' ([bool]$orig) "selected: $orig"
    if (-not $orig) { return }
    try {
        Check '"Going back to Home": Disconnect it is selected' (Select-SlRadio $dropRe) ''
        $null = Use-Machine $Ctx
        $v = Focus-SlViewer
        if (-not $v) { Check '"Disconnect it": the viewer is open before Ctrl+Alt+Shift+H' $false ''; return }
        $front = [E2E]::Foreground()
        [E2E]::Combo([byte][char]'H')
        $gone = Wait-For { -not (Get-Process -Id $v.Id -ErrorAction SilentlyContinue) } 15
        $s = Screen
        Check '"Disconnect it": Ctrl+Alt+Shift+H ends the viewer within 15 s' ([bool]$gone) "viewer $($v.Id); in front when pressed: $front; at the center now: $([E2E]::ProcessNameAt($s.X + [int]($s.Width / 2), $s.Y + [int]($s.Height / 2)))"
    }
    finally {
        $opened = Open-SlSettings $window
        $back = $opened -and (Select-SlRadio $orig)
        $how = ''
        if (-not $back) {
            # The picture may still be coming up in front: once more from Home.
            Start-Sleep -Seconds 3
            $back = (Open-SlSettings $window) -and (Select-SlRadio $orig)
            $how = "second try (first: Settings > Window opened $opened)"
        }
        Check "going back to Home is restored to $(Get-SlLabel $orig)" $back $how
        try { $null = Use-Machine $Ctx } catch { }
        Check 'the machine opens in the viewer again' ([bool](Get-SlViewer)) ''
        Exit-SlViewer
    }
}

# The time to answer is read when an agent connects, so a second session started after the change is the one asked.
function Test-SlTimeToAnswer($Ctx, [string]$Tag) {
    $agentsTab = '^(Agents|Agentes)$'
    # Right after the replay test the viewer can still be closing and take the first click.
    if (-not (Open-SlSettings $agentsTab)) {
        Start-Sleep 2
        if (-not (Open-SlSettings $agentsTab)) { Check 'Settings > Agents opens' $false 'second try too'; return }
    }
    $getSlider = { Find-SlOne (Get-MainElement) 'Slider' '^(Time to answer|Tiempo para responder)$' }
    $orig = Get-SlValue (& $getSlider)
    Check 'the time to answer is readable' ($orig -ge 0) "index $orig"
    if ($orig -lt 0) { return }
    $origSec = $null
    try {
        Import-Module (Join-Path $PSScriptRoot '..\..\..\src\GpuVM\GpuVM.psd1') -ErrorAction Stop
        $origSec = [int](Get-GpuVMAgentSettings).approvalTimeoutSec
    } catch { Write-Host "     the time to answer in seconds isn't readable: $($_.Exception.Message)" }
    $vm = $Ctx.Machine
    $s2 = $null; $released = $false
    try {
        $null = Set-SlSliderMin (& $getSlider)
        $min = Wait-For { (Get-SlValue (& $getSlider)) -eq 0 } 3
        Check 'Time to answer goes to its minimum' ([bool]$min) "index $(Get-SlValue (& $getSlider))"
        # The service has it a few seconds later (an agent connecting before then still gets the old time).
        $saved = Wait-For { try { [int](Get-GpuVMAgentSettings).approvalTimeoutSec -eq 60 } catch { $false } } 20
        Check 'Time to answer: the service has the minimum (60 s)' ([bool]$saved) "service: $(try { (Get-GpuVMAgentSettings).approvalTimeoutSec } catch { '?' }) s"
        Start-Sleep -Seconds 1
        # Requests show as a dock over the picture only while the picture is on screen.
        $vm = Use-Machine $Ctx

        $t = Invoke-SlCall $Ctx.Mcp 'release_machine' @{ machine = $vm } 30
        $released = $t -match 'Released'
        Check 'the suite''s agent lends the machine to a second agent' $released $t
        if (-not $released) { return }
        $s2 = Start-Mcp $Ctx.Exe 'E2eTimeout'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $id = Start-Tool $s2 'take_machine' @{ machine = $vm; waitSeconds = 120; task = "Time to answer $Tag" }
        $dock = Wait-For { Find-SlDock "Use (the machine )?'?$([regex]::Escape($vm))|Usar (la m.quina )?'?$([regex]::Escape($vm))" } 10
        $reply = Get-SlText (Wait-SlReply $s2 $id 150)
        if ($reply -match 'You have') {
            $title = "e2e-$Tag unanswered"
            $sw.Restart()
            $id = Start-Tool $s2 'request_approval' @{ machine = $vm; kind = 'other'; title = $title; reason = 'End-to-end check of the time to answer.' }
            $dock = Wait-For { Find-SlDock ([regex]::Escape($title)) } 15
            Check 'the unanswered request shows a dock' ([bool]$dock) ''
            $reply = Get-SlText (Wait-SlReply $s2 $id 150)
            $pattern = [regex]::Escape($title)
        }
        else {
            Check 'the second agent''s request to use the machine shows a dock' ([bool]$dock) ''
            $pattern = "Use (the machine )?'?$([regex]::Escape($vm))|Usar (la m.quina )?'?$([regex]::Escape($vm))"
        }
        $secs = [int]$sw.Elapsed.TotalSeconds
        Check 'Time to answer at its minimum: the unanswered request ends as not answered and withdrawn' ((($reply -match "didn't answer" -and $reply -match 'withdrawn') -or $reply -match 'expired without an answer') -and $secs -lt 120) "after $secs s: $reply"
        Check 'the withdrawn request''s dock goes' ([bool](Wait-For { -not (Find-SlDock $pattern) } 10)) ''
    }
    finally {
        if ($s2) { try { $null = Invoke-SlCall $s2 'release_machine' @{ machine = $vm } 30 } catch { }; Stop-Mcp $s2 }
        if ($released) {
            $id = Start-Tool $Ctx.Mcp 'take_machine' @{ machine = $vm; waitSeconds = 120; task = 'End-to-end suite' }
            $reply = $null
            $deadline = (Get-Date).AddSeconds(150)
            while (-not $reply -and (Get-Date) -lt $deadline) {
                $d = Find-SlDock "Use (the machine )?'?$([regex]::Escape($vm))|Usar (la m.quina )?'?$([regex]::Escape($vm))"
                if ($d) { $b = Find-Named $d.Root '^\W*(Allow|Permitir)\W*$' ([Windows.Automation.ControlType]::Button); if ($b) { $null = Click-Element $b } }
                $reply = Wait-SlReply $Ctx.Mcp $id 2
            }
            $t = Get-SlText $reply
            Check 'the suite''s agent takes the machine back' ($t -match 'You have') $t
        }
        $null = Open-SlSettings $agentsTab
        $restored = Set-SlSliderIndex (& $getSlider) $orig
        Check 'the time to answer goes back to what it was' $restored "index $(Get-SlValue (& $getSlider)), was $orig"
        if (-not $restored -and $origSec) {
            try { Set-GpuVMAgentSettings -ApprovalTimeoutSec $origSec | Out-Null; Write-Host "     time to answer put back to $origSec s through Set-GpuVMAgentSettings" } catch { Write-Host "     couldn't put the time to answer back: $($_.Exception.Message)" }
        }
    }
}

function Get-SlVideosDir {
    $el = Find-SlAll (Get-MainElement) '' ', (one folder per machine|una carpeta por máquina)$' | Select-Object -Last 1
    if ($el) { return $el.Current.Name -replace ', (one folder per machine|una carpeta por máquina)$', '' }
    Join-Path ([Environment]::GetFolderPath('MyVideos')) 'GpuVM'
}

function Get-SlFiles([string]$Dir) { if (Test-Path -LiteralPath $Dir) { @(Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object FullName) } else { @() } }

function Test-SlReplay($Ctx) {
    $captures = '^(Captures|Capturas)$'
    $offRe = '^(Off|Desactivado)$'
    $onRe = '^(On|Activado)$'
    if (-not (Open-SlSettings $captures)) { Check 'Settings > Captures opens' $false ''; return }
    $orig = Read-SlRadio @($offRe, $onRe)
    Check 'the "last 30 s" setting is readable' ([bool]$orig) "selected: $orig"
    if (-not $orig) { return }
    $dir = Get-SlVideosDir
    try {
        Check '"Save the last 30 s" turns on' (Select-SlRadio $onRe) ''
        $null = Use-Machine $Ctx
        Start-Sleep -Seconds 35
        $before = Get-SlFiles $dir
        $null = Focus-SlViewer
        [E2E]::Combo([byte][char]'B')
        $n = Wait-Notch 'Clip saved|Clip guardado' 15
        Check 'last 30 s on: Ctrl+Alt+Shift+B shows "Clip saved"' ($n -and $n.Text -match 'Clip saved|Clip guardado') "notch: $($n.Text)"
        Shot 'settings-replay-clip'
        $new = Wait-For { $x = @(Get-SlFiles $dir | Where-Object { $before -notcontains $_ -and (Get-Item -LiteralPath $_).Length -gt 0 }); if ($x.Count) { $x } } 25
        Check 'the clip is a new video file' ([bool]$new) $(if ($new) { $new[0] } else { "nothing new in $dir" })

        if (-not (Open-SlSettings $captures)) { throw 'Settings > Captures did not open again.' }
        Check '"Save the last 30 s" turns off' (Select-SlRadio $offRe) ''
        $null = Use-Machine $Ctx
        $null = Focus-SlViewer
        [E2E]::Combo([byte][char]'B')
        $n = Wait-Notch 'Turn on the last 30 s|Activa los últimos 30 s' 10
        Check 'last 30 s off: Ctrl+Alt+Shift+B says to turn it on' ($n -and $n.Text -match 'Turn on the last 30 s|Activa los últimos 30 s') "notch: $($n.Text)"
    }
    finally {
        $null = Open-SlSettings $captures
        Check "the last 30 s go back to $(Get-SlLabel $orig)" (Select-SlRadio $orig) ''
    }
}

function Test-SlTitleBar {
    Exit-SlViewer
    $h = (Get-App).MainWindowHandle
    $getButton = { param($p) $top = [E2E]::Rect($h)[1]; Find-SlAll (Get-MainElement) 'Button' $p | Where-Object { $_.Current.BoundingRectangle.Y -lt $top + 60 } | Select-Object -First 1 }
    $wasZoomed = [E2ESL]::IsZoomed($h)
    try {
        $null = Press-SlReal (& $getButton '^(Minimize|Minimizar)$')
        Check 'title bar Minimize minimizes the window' ([bool](Wait-For { [E2ESL]::IsIconic($h) } 4)) ''
        $null = [E2ESL]::ShowWindow($h, 9); $null = [E2ESL]::Front($h)
        Check 'the minimized window comes back' ([bool](Wait-For { -not [E2ESL]::IsIconic($h) } 4)) ''
        Start-Sleep -Milliseconds 500
        $covers = { $r = [E2E]::Rect($h); $wa = [Windows.Forms.Screen]::FromHandle($h).WorkingArea; $r[0] -le $wa.X + 2 -and $r[1] -le $wa.Y + 2 -and $r[0] + $r[2] -ge $wa.Right - 2 -and $r[1] + $r[3] -ge $wa.Bottom - 2 }
        $steps = if ($wasZoomed) { @('restore', 'maximize') } else { @('maximize', 'restore') }
        foreach ($s in $steps) {
            if ($s -eq 'maximize') {
                $null = Press-SlReal (& $getButton '^(Maximize|Maximizar)$')
                $ok = Wait-For { [E2ESL]::IsZoomed($h) -and (& $covers) } 4
                $r = [E2E]::Rect($h); $wa = [Windows.Forms.Screen]::FromHandle($h).WorkingArea
                Check 'title bar Maximize: the window covers the work area' ([bool]$ok) "window $($r -join ','), work area $($wa.X),$($wa.Y),$($wa.Width),$($wa.Height)"
            }
            else {
                $null = Press-SlReal (& $getButton '^(Restore|Restaurar)$')
                Check 'title bar Restore un-maximizes the window' ([bool](Wait-For { -not [E2ESL]::IsZoomed($h) } 4)) "window $([E2E]::Rect($h) -join ',')"
            }
            Start-Sleep -Milliseconds 500
        }
    }
    finally {
        if ([E2ESL]::IsIconic($h)) { $null = [E2ESL]::ShowWindow($h, 9) }
        if ($wasZoomed -and -not [E2ESL]::IsZoomed($h)) { $null = [E2ESL]::ShowWindow($h, 3) }
        if (-not $wasZoomed -and [E2ESL]::IsZoomed($h)) { $null = [E2ESL]::ShowWindow($h, 9) }
        $null = Show-SlMain
    }
}

function Get-SlSpaceTab([string]$Name) { Find-SlOne (Get-MainElement) 'RadioButton' "^\s*$([regex]::Escape($Name))\s*$" }

# -Invoke is for cleanup after a failed check: it leaves no space behind even when a real click can't reach a button.
function Remove-SlSpace([string]$Name, [switch]$Invoke) {
    $esc = [regex]::Escape($Name)
    $press = if ($Invoke) { { param($e) Invoke-Element $e } } else { { param($e) Press-SlReal $e } }
    $null = & $press (Get-SlSpaceTab $Name)
    $edit = Wait-For { Find-SlOne (Get-MainElement) 'Button' "^(Edit|Editar) $esc$" } 3
    $null = & $press $edit
    $dlg = Wait-For { Get-SlDialog "^(Edit|Editar) $esc$" } 4
    if (-not $dlg) { return $false }
    $null = & $press (Find-SlOne $dlg 'Button' '^(Delete space|Eliminar espacio)$')
    $confirm = Wait-For { Find-SlOne (Get-SlDialog "^(Edit|Editar) $esc$") 'Button' '^(Delete|Eliminar)$' } 3
    $null = & $press $confirm
    [bool](Wait-For { -not (Get-SlSpaceTab $Name) } 4)
}

function Test-SlSpaces([string]$Tag) {
    $name = "e2e-$Tag"
    $esc = [regex]::Escape($name)
    if (-not (Open-SlSide '^(Home|Inicio)$')) { Check 'Home opens' $false ''; return }
    # The suite's first step: right after GpuVM starts, Home can still be loading its machines.
    $plus = Wait-For { Find-SlOne (Get-MainElement) 'Button' '^(New space|Nuevo espacio)$' } 15
    Check 'Home has the New space button' ([bool]$plus) ''
    if (-not $plus) { return }
    $created = $false
    try {
        $null = Press-SlReal $plus
        $dlg = Wait-For { Get-SlDialog '^(New space|Nuevo espacio)$' } 4
        Check '"New space" opens its dialog' ([bool]$dlg) ''
        if (-not $dlg) { return }
        $typed = Set-SlText (Find-SlOne $dlg 'Edit') $name
        $null = Press-SlReal (Find-SlOne $dlg 'Button' '^(Create space|Crear espacio)$')
        $tab = Wait-For { Get-SlSpaceTab $name } 5
        $created = [bool]$tab
        Check "the new space $name gets its tab" ($typed -and $created) ''
        if (-not $created) { return }
        Shot 'spaces-created'

        $null = Press-SlReal (Find-SlOne (Get-MainElement) 'Button' "^(Edit|Editar) $esc$")
        $dlg = Wait-For { Get-SlDialog "^(Edit|Editar) $esc$" } 4
        Check "Edit $name opens its dialog" ([bool]$dlg) ''
        if ($dlg) {
            $other = Find-SlAll $dlg 'RadioButton' '' '\bspace-ambient\b' | Where-Object { -not (Test-SlOn $_) } | Select-Object -First 1
            $null = Press-SlReal $other
            $null = Press-SlReal (Find-SlOne $dlg 'Button' '^(Save|Guardar)$')
            $closed = Wait-For { -not (Get-SlDialog "^(Edit|Editar) $esc$") } 4
            Check "editing $name saves and keeps its tab" ([bool]$closed -and [bool](Get-SlSpaceTab $name)) ''
        }

        $gone = Remove-SlSpace $name
        Check "deleting $name removes its tab" $gone ''
        if ($gone) { $created = $false }
    }
    finally {
        Close-SlDialogs
        if ($created) { Close-SlDialogs; $null = Remove-SlSpace $name -Invoke }
    }
}

function Remove-SlProfile([string]$Name) {
    $card = Get-SlCard $Name
    if (-not $card) { return $true }
    $null = Press-SlReal (Find-SlOne $card 'Button' "^(Delete|Eliminar) $([regex]::Escape($Name))$")
    $confirm = Wait-For { $c = Get-SlCard $Name; if ($c) { Find-SlOne $c 'Button' '^(Confirm|Confirmar)$' } } 3
    $null = Press-SlReal $confirm
    [bool](Wait-For { -not (Get-SlCard $Name) } 15)
}

function Test-SlProfiles([string]$Tag) {
    $name = "e2e-$Tag"
    $esc = [regex]::Escape($name)
    if (-not (Open-SlLibraryTab '^(Profiles|Perfiles)$')) { Check 'Library > Profiles opens' $false ''; return }
    $dup = Wait-For {
        Find-SlAll (Get-MainElement) 'Button' '^(Duplicate|Duplicar)$' | Where-Object {
            $p = $_
            for ($i = 0; $i -lt 6 -and $p -and $p.Current.ClassName -notmatch '\bprofile-card\b'; $i++) { $p = [Windows.Automation.TreeWalker]::RawViewWalker.GetParent($p) }
            $p -and (Get-Texts $p) -match '\b(Built-in|Incluido)\b'
        } | Select-Object -First 1
    } 8
    Check 'a built-in profile offers Duplicate' ([bool]$dup) ''
    if (-not $dup) { return }
    $saved = $false
    try {
        $null = Press-SlReal $dup
        $dlg = Wait-For { Get-SlDialog '^(New profile|Nuevo perfil)$' } 5
        Check 'Duplicate opens the new profile dialog' ([bool]$dlg) ''
        if (-not $dlg) { return }
        $box = Find-SlOne $dlg 'Edit' '^(Name|Nombre)'
        if (-not $box) { $box = Find-SlOne $dlg 'Edit' }
        $typed = Set-SlText $box $name
        $null = Press-SlReal (Find-SlOne $dlg 'Button' '^(Save profile|Guardar perfil)$')
        $toast = Wait-For { (Get-Texts (Get-MainElement)) -match "(Profile|Perfil) $esc (saved|guardado)" } 30
        Check "Save profile: a toast says $name was saved" ($typed -and [bool]$toast) ''
        $card = Wait-For { Get-SlCard $name } 10
        $saved = [bool]$card
        Check "the profile $name shows as a card" $saved ''
        if (-not $saved) { return }
        Shot 'library-profile-saved'

        $desc = "e2e description $Tag"
        $null = Press-SlReal (Find-SlOne $card 'Button' '^(Edit|Editar)$')
        $dlg = Wait-For { Get-SlDialog "^(Edit|Editar) $esc$" } 5
        Check "Edit opens $name" ([bool]$dlg) ''
        if ($dlg) {
            $box = Find-SlOne $dlg 'Edit' '^(Description|Descripción)'
            if (-not $box) { $box = @(Find-SlAll $dlg 'Edit')[1] }
            $typed = Set-SlText $box $desc
            Shot 'library-profile-edit'
            $null = Press-SlReal (Find-SlOne $dlg 'Button' '^(Save profile|Guardar perfil)$')
            $shown = Wait-For { $c = Get-SlCard $name; $c -and (Get-SlCardTexts $c) -match [regex]::Escape($desc) } 20
            Check "the edited description shows on $name's card" ($typed -and [bool]$shown) "typed: $typed; box: $(if ($box) { $box.Current.Name } else { 'none' }); card: $(if ($c = Get-SlCard $name) { Get-SlCardTexts $c } else { 'not found' })"
        }

        $gone = Remove-SlProfile $name
        Check "Delete then Confirm removes $name" $gone ''
        if ($gone) { $saved = $false }
    }
    finally {
        Close-SlDialogs
        if ($saved) { $null = Remove-SlProfile $name }
    }
}

# Deleting it from the app asks for administrator permission, so the run's cleanup deletes it afterwards.
function Test-SlSharedDisk([string]$Tag) {
    $name = "e2e-$Tag"
    $esc = [regex]::Escape($name)
    if (-not (Open-SlLibraryTab '^(Shared disks|Discos compartidos)$')) { Check 'Library > Shared disks opens' $false ''; return }
    $new = Wait-For { Find-SlOne (Get-MainElement) 'Button' '^(New disk|Nuevo disco)$' } 8
    $null = Press-SlReal $new
    $dlg = Wait-For { Get-SlDialog '^(New shared disk|Nuevo disco compartido)$' } 5
    Check '"New disk" opens the shared disk dialog' ([bool]$dlg) ''
    if (-not $dlg) { return }
    $typed = Set-SlText (Find-SlOne $dlg 'Edit') $name
    $null = Press-SlReal (Find-SlOne $dlg 'RadioButton' '^General$')
    $size = Find-SlOne $dlg 'Slider' '^(Size|Tamaño)$'
    $null = Set-SlSliderMin $size
    Start-Sleep -Milliseconds 300
    $gb = Get-SlValue (Find-SlOne (Get-SlDialog '^(New shared disk|Nuevo disco compartido)$') 'Slider' '^(Size|Tamaño)$')
    $null = Press-SlReal (Find-SlOne $dlg 'Button' '^(Create disk|Crear disco)$')
    $toast = Wait-For { (Get-Texts (Get-MainElement)) -match "(Disk|Disco) $esc (created|creado)" } 90
    Check "Create disk: a toast says $name was created" ($typed -and [bool]$toast) "smallest size the dialog allows: $gb GB"
    $card = Wait-For { Get-SlCard $name 'Disks' } 15
    Check "the shared disk $name is listed" ([bool]$card) ''
    if ($card) {
        Shot 'library-shared-disk'
    }
}

# The score's span has no box in UI Automation: its text sits just before the lives (which have a label).
function Get-SlScore {
    $root = Get-MainElement
    $el = Find-SlOne $root '' '' '\bgame-(score|final)\b'
    if (-not $el) {
        $lives = Find-SlOne $root '' '' '\bgame-lives\b'
        if ($lives) { $el = [Windows.Automation.TreeWalker]::RawViewWalker.GetPreviousSibling($lives) }
        if ($el -and $el.Current.Name -notmatch '\d') { $el = $null }
    }
    if (-not $el) { return $null }
    $t = if ($el.Current.Name) { $el.Current.Name } else { Get-Texts $el }
    ($t -replace '[^\d]', '')
}

function Test-SlGame {
    if (-not (Open-SlSide '^(Home|Inicio)$')) { Check 'Home opens' $false ''; return }
    $play = Wait-For { Find-SlOne (Get-MainElement) 'Button' '^(Play|Jugar)$' '\bspace-play\b' } 5
    if (-not $play) {
        $first = Find-SlAll (Get-MainElement) 'RadioButton' | Where-Object { $_.Current.ClassName -notmatch 'swatch' } | Select-Object -First 1
        $null = Press-SlReal $first
        $play = Wait-For { Find-SlOne (Get-MainElement) 'Button' '^(Play|Jugar)$' '\bspace-play\b' } 5
    }
    Check 'Home offers Play' ([bool]$play) ''
    if (-not $play) { return }
    try {
        $null = Press-SlReal $play
        $tile = Wait-For { Find-SlOne (Get-MainElement) 'Button' '^(Play|Jugar) Stack$' } 5
        Check 'Play opens the games gallery with Stack' ([bool]$tile) ''
        if (-not $tile) { return }
        $null = Press-SlReal $tile
        $start = Wait-For { Find-SlOne (Get-MainElement) 'Button' '^(Play|Jugar)$' '\bprimary\b' } 5
        $null = Press-SlReal $start
        $s0 = Wait-For { Get-SlScore } 5
        Check 'Stack starts with a score' ($null -ne $s0 -and $s0 -ne '') "score: $s0"
        $null = Show-SlMain
        for ($i = 0; $i -lt 4; $i++) { Start-Sleep -Milliseconds 800; [E2ESL]::Key(0x20) }
        $s1 = Wait-For { $x = Get-SlScore; if ($x -and $x -ne $s0) { $x } } 3
        Check 'pressing Space in Stack changes the score' ([bool]$s1) "score $s0 -> $(Get-SlScore)"
        Shot 'game-stack'
        $exit = Find-SlOne (Get-MainElement) 'Button' '^(Exit the game|Salir del juego|Exit|Salir)$'
        $null = Press-SlReal $exit
        $left = Wait-For { -not (Get-SlScore) } 4
        Check 'Exit leaves the game' ([bool]$left) ''
    }
    finally {
        for ($i = 0; $i -lt 3 -and ((Get-SlScore) -ne $null -or (Find-SlOne (Get-MainElement) '' '' '\bgame-gallery\b')); $i++) { $null = Show-SlMain; [E2ESL]::Key(0x1B); Start-Sleep -Milliseconds 500 }
        Check 'the game and its gallery close' (-not (Find-SlOne (Get-MainElement) '' '' '\bgame-(gallery|stage)\b')) ''
    }
}

# Settings > Service > Save report: a text file in Downloads with the app's and the service's logs, shown in Explorer.
function Test-SlDiagnostics {
    # Right after the time-to-answer check the picture has just been in front: the page can take a moment to read again.
    $open = Open-SlSettings '^(Service|Servicio)$'
    if (-not $open) { Start-Sleep -Seconds 2; $open = Open-SlSettings '^(Service|Servicio)$' }
    if (-not $open) { Check 'Settings > Service opens' $false ''; return }
    $downloads = (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path
    $before = @(Get-ChildItem -LiteralPath $downloads -Filter 'GpuVM-report-*.txt' -ErrorAction SilentlyContinue | ForEach-Object FullName)
    $explorers = @(Get-Process explorer -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    $b = Wait-For { Find-SlOne (Get-MainElement) 'Button' '^\W*(Save report|Guardar informe)\W*$' } 5
    Check 'Settings > Service shows Save report' ([bool]$b) ''
    if (-not $b) { return }
    $null = Press-SlReal $b
    $new = Wait-For { Get-ChildItem -LiteralPath $downloads -Filter 'GpuVM-report-*.txt' -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.FullName } | Select-Object -First 1 } 15
    $text = if ($new) { Get-Content -Raw -LiteralPath $new.FullName } else { '' }
    Check 'Save report writes the report to Downloads with the app''s and the service''s logs' ($text -match 'diagnostics report' -and $text -match 'app\.log' -and $text -match 'host\.log') $(if ($new) { $new.Name } else { 'no new GpuVM-report file' })
    $said = Wait-For { Find-SlOne (Get-MainElement) '' '(Saved in Downloads|Guardado en Descargas)' } 5
    Check 'the row says where it was saved' ([bool]$said) ''
    $shown = Wait-For { Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -match 'Downloads|Descargas' } | Select-Object -First 1 } 8
    Check 'Explorer opens on Downloads' ([bool]$shown) ''
    if ($shown -and $explorers -notcontains $shown.Id) { Stop-Process -Id $shown.Id -ErrorAction SilentlyContinue }
    elseif ($shown) { $null = $shown.CloseMainWindow() }
    if ($new) { Remove-Item -LiteralPath $new.FullName -ErrorAction SilentlyContinue }
}

function Test-Suite($Ctx) {
    if (-not (Get-App)) { throw 'GpuVM is not running.' }
    $tag = "$(Get-Random -Minimum 100000 -Maximum 999999)"
    Step-Sl 'language' { Test-SlLanguage }
    Step-Sl 'accent color' { Test-SlAccent }
    Step-Sl 'title bar' { Test-SlTitleBar }
    Step-Sl 'spaces' { Test-SlSpaces $tag }
    Step-Sl 'profiles' { Test-SlProfiles $tag }
    Step-Sl 'shared disks' { Test-SlSharedDisk $tag }
    Step-Sl 'games' { Test-SlGame }
    Step-Sl 'notice placement' { Test-SlNotchPlacement $Ctx $tag }
    Step-Sl 'going back to Home' { Test-SlDisconnect $Ctx }
    Step-Sl 'last 30 s' { Test-SlReplay $Ctx }
    Step-Sl 'time to answer' { Test-SlTimeToAnswer $Ctx $tag }
    Step-Sl 'diagnostics report' { Test-SlDiagnostics }
    Exit-SlViewer
    $app = Get-App
    Check 'the app still responds after the settings checks' ($app -and $app.Responding) ''
}
