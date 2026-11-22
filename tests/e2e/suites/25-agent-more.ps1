# More of the agent's world: who it is in the machine, refusals, "allow for this task", the remaining tool parameters
# and the recording of its work. Every dock answer is a real click.

if (-not ('E2EMore' -as [type])) {
    Add-Type @'
using System; using System.Runtime.InteropServices;
public static class E2EMore {
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  public static void RightClick(int x, int y) { SetCursorPos(x - 40, y - 30); System.Threading.Thread.Sleep(80); for (int i = 1; i <= 8; i++) { SetCursorPos(x - 40 + 5 * i, y - 30 + (30 * i) / 8); System.Threading.Thread.Sleep(15); } System.Threading.Thread.Sleep(150); mouse_event(8,0,0,0,IntPtr.Zero); System.Threading.Thread.Sleep(40); mouse_event(16,0,0,0,IntPtr.Zero); }
}
'@
}

function Wait-AgentReply($Session, [int]$Id, [double]$Seconds) {
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

function Invoke-AgentCall($Session, [string]$Name, [hashtable]$Arguments = @{}, [double]$Seconds = 90) {
    Wait-AgentReply $Session (Start-Tool $Session $Name $Arguments) $Seconds
}

function Get-ReplyText($Reply) {
    if ($null -eq $Reply) { return '(no answer in time)' }
    if ($Reply.error) { return "JSON-RPC error: $($Reply.error.message)" }
    Text-Of $Reply
}

function Test-ReplyError($Reply) { [bool]($Reply -and $Reply.result.isError) }

function Get-ReplyImage($Reply) { if ($Reply) { @($Reply.result.content) | Where-Object type -eq 'image' | Select-Object -First 1 } }

function Get-AgentShot($Session, [string]$Machine, [hashtable]$Extra = @{}) {
    $a = @{ machine = $Machine; format = 'png' }
    foreach ($k in $Extra.Keys) { $a[$k] = $Extra[$k] }
    $r = Invoke-AgentCall $Session 'screenshot' $a 60
    $t = Get-ReplyText $r
    $m = [regex]::Match($t, '(\d+)x(\d+) \(desktop')
    [pscustomobject]@{ Reply = $r; Text = $t; Image = (Get-ReplyImage $r); W = $(if ($m.Success) { [int]$m.Groups[1].Value } else { 0 }); H = $(if ($m.Success) { [int]$m.Groups[2].Value } else { 0 }) }
}

# Share of a grid of points in a box (fractions of the screenshots) whose color changed between two PNG screenshots.
function Get-ChangedShare($ImageA, $ImageB, [double]$X, [double]$Y, [double]$W, [double]$H) {
    if (-not $ImageA -or -not $ImageB) { return -1 }
    $load = { param($i) $ms = [IO.MemoryStream]::new([Convert]::FromBase64String($i.data)); [Drawing.Bitmap]::new($ms) }
    $a = & $load $ImageA; $b = & $load $ImageB
    $n = 0; $changed = 0
    for ($i = 0; $i -lt 30; $i++) { for ($j = 0; $j -lt 30; $j++) {
        $px = [int](($X + $W * $i / 30) * $a.Width); $py = [int](($Y + $H * $j / 30) * $a.Height)
        if ($px -ge $b.Width -or $py -ge $b.Height) { continue }
        $p = $a.GetPixel($px, $py); $q = $b.GetPixel($px, $py); $n++
        if ([Math]::Abs($p.R - $q.R) + [Math]::Abs($p.G - $q.G) + [Math]::Abs($p.B - $q.B) -gt 20) { $changed++ }
    } }
    $a.Dispose(); $b.Dispose()
    if ($n) { $changed / $n } else { -1 }
}

# Share of non-white pixels (text in any gray) in a box given as fractions of a PNG screenshot: the screenshot is
# scaled down, so thin dark glyphs arrive as light grays that a darkness threshold misses.
function Get-InkShare($Image, [double]$X, [double]$Y, [double]$W, [double]$H) {
    if (-not $Image -or $Image.mimeType -ne 'image/png') { return -1 }
    $ms = [IO.MemoryStream]::new([Convert]::FromBase64String($Image.data))
    $bmp = [Drawing.Bitmap]::new($ms)
    $rect = [Drawing.Rectangle]::new([int]($bmp.Width * $X), [int]($bmp.Height * $Y), [int]($bmp.Width * $W), [int]($bmp.Height * $H))
    $crop = $bmp.Clone($rect, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $ink = 1 - [E2E]::Tones((Bytes $crop))[1]
    $crop.Dispose(); $bmp.Dispose(); $ms.Dispose()
    $ink
}

function Get-DarkShare($Image, [double]$X, [double]$Y, [double]$W, [double]$H) {
    if (-not $Image -or $Image.mimeType -ne 'image/png') { return -1 }
    $ms = [IO.MemoryStream]::new([Convert]::FromBase64String($Image.data))
    $bmp = [Drawing.Bitmap]::new($ms)
    $rect = [Drawing.Rectangle]::new([int]($bmp.Width * $X), [int]($bmp.Height * $Y), [int]($bmp.Width * $W), [int]($bmp.Height * $H))
    $crop = $bmp.Clone($rect, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $dark = [E2E]::Tones((Bytes $crop))[0]
    $crop.Dispose(); $bmp.Dispose(); $ms.Dispose()
    $dark
}

function Find-AgentDock([string]$Pattern, [string]$Button) {
    $app = Get-App
    $main = if ($app) { $app.MainWindowHandle } else { [IntPtr]::Zero }
    foreach ($w in Get-AppWindows) {
        if ($w.Handle -eq $main) { continue }
        try {
            $root = Get-Element $w.Handle
            $texts = Get-Texts $root
            if ($texts -match $Pattern -and (Find-Named $root $Button ([Windows.Automation.ControlType]::Button))) { return [pscustomobject]@{ Root = $root; Texts = $texts } }
        } catch { }
    }
    $null
}

function Wait-AgentWindow($Session, [string]$Machine, [string]$Pattern, [double]$Seconds = 25) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $t = Get-ReplyText (Invoke-AgentCall $Session 'ui_tree' @{ machine = $Machine; interactiveOnly = $false; maxNodes = 5 } 30)
        if ($t -match $Pattern) { return $t }
        # A Windows banner that took the focus is closed, as an agent would.
        if ($t -match '(?m)^\S+ window "(Nueva notificaci|New notification)') { $null = Invoke-AgentCall $Session 'key' @{ machine = $Machine; keys = 'escape' } 30 }
        Start-Sleep -Milliseconds 700
    } while ((Get-Date) -lt $deadline)
    $t
}

function Step-Agent([string]$Name, [scriptblock]$Body) {
    try { & $Body } catch { Check "$Name ran to the end" $false $_.Exception.Message }
}

# Waits for the dock and its button to be enabled (armed), then clicks it like a person.
function Click-AgentDock([string]$Pattern, [string]$Button, [double]$Seconds = 20) {
    $res = [pscustomobject]@{ Found = $false; Pressed = $false; Texts = ''; Root = $null }
    $dock = Wait-For { Find-AgentDock $Pattern $Button } $Seconds
    if (-not $dock) { return $res }
    $res.Found = $true; $res.Texts = $dock.Texts; $res.Root = $dock.Root
    $deadline = (Get-Date).AddSeconds(10)
    while (-not $res.Pressed -and (Get-Date) -lt $deadline) {
        $b = Find-Named $dock.Root $Button ([Windows.Automation.ControlType]::Button)
        if ($b -and $b.Current.IsEnabled) { Start-Sleep -Milliseconds 300; try { $res.Pressed = [bool](Click-Element $b) } catch { } }
        if (-not $res.Pressed) { Start-Sleep -Milliseconds 250 }
    }
    $res
}

function Test-DockGone([string]$Pattern, [string]$Button) { [bool](Wait-For { -not (Find-AgentDock $Pattern $Button) } 10) }

function RightClick-Element($Element, [string]$Process = 'gpuvm') {
    if (-not $Element) { return $false }
    $r = $Element.Current.BoundingRectangle
    if ($r.Width -le 0 -or $r.Height -le 0) { return $false }
    $x = [int]($r.X + $r.Width / 2); $y = [int]($r.Y + $r.Height / 2)
    $at = [E2E]::ProcessNameAt($x, $y)
    if ($at -ne $Process) { Write-Host "     right-click refused: $at is over '$($Element.Current.Name)'"; return $false }
    [E2EMore]::RightClick($x, $y)
    $true
}

function Find-AppNamed([string]$Pattern) {
    foreach ($w in Get-AppWindows) {
        $e = Find-Named (Get-Element $w.Handle) $Pattern ([Windows.Automation.ControlType]::MenuItem)
        if (-not $e) { $e = Find-Named (Get-Element $w.Handle) $Pattern ([Windows.Automation.ControlType]::Button) }
        if ($e) { return $e }
    }
    $null
}

function Get-TreeCentre([string]$Tree, [string]$NamePattern) {
    $m = [regex]::Match($Tree, "(?m)^\S+ \S+ ""[^""\n]*$NamePattern[^""\n]*""[^\n]*centre \((\d+), (\d+)\)")
    if ($m.Success) { @([int]$m.Groups[1].Value, [int]$m.Groups[2].Value) }
}

function Get-TreeId([string]$Tree, [string]$NamePattern) {
    $m = [regex]::Match($Tree, "(?m)^(\S+) \S+ ""$NamePattern""")
    if ($m.Success) { $m.Groups[1].Value }
}

function Test-Suite($Ctx) {
    $S = $Ctx.Mcp
    if ($S.PSObject.Properties.Name -contains 'Pending' -and $S.Pending) { $null = $S.Pending.Wait(30000); $S.Pending = $null }
    $suiteStart = Get-Date
    $vm = Use-Machine $Ctx
    $tag = "e2e$(Get-Random -Minimum 100000 -Maximum 999999)"
    $st = @{ Home = 'C:\Users\agent' }
    $allow = '^\W*(Allow|Permitir)\W*$'
    $refuse = '^\W*(Refuse|Rechazar)\W*$'
    $accept = '^\W*(Accept|Aceptar)\W*$'
    $forTask = '^\W*(Allow for this task|Permitir en esta tarea)\W*$'
    $notepad = 'Notepad|Bloc de notas'
    $dl = Join-Path $env:USERPROFILE 'Downloads\GpuVM'
    $closeApps = { $null = Invoke-AgentCall $S 'run' @{ machine = $vm; command = 'Stop-Process -Name notepad, mspaint -Force -ErrorAction SilentlyContinue' } 60 }
    try {
        Step-Agent 'standard user' {
            $t = Get-ReplyText (Invoke-AgentCall $S 'run' @{ machine = $vm; command = '"admin=" + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator); "user=" + (whoami)' } 60)
            Check 'the agent is not in the Administrators role' ($t -match '(?m)^admin=False\s*$') $t
            Check 'whoami in the machine is the agent user' ($t -match '(?mi)^user=.*\\agent\s*$') $t
            $h = [regex]::Match((Get-ReplyText (Invoke-AgentCall $S 'run' @{ machine = $vm; command = '$env:USERPROFILE' } 60)), '--- stdout ---\n([^\r\n]+)')
            if ($h.Success) { $st.Home = $h.Groups[1].Value.Trim() }
            $t = Get-ReplyText (Invoke-AgentCall $S 'run' @{ machine = $vm; command = 'winget --version; exit $LASTEXITCODE'; timeoutSeconds = 120 } 150)
            Check 'winget works for the agent' ($t -match 'Exit code 0' -and $t -match 'v\d+\.\d+') $t
            $t = Get-ReplyText (Invoke-AgentCall $S 'run' @{ machine = $vm; command = 'winget source list | Out-String -Width 200'; timeoutSeconds = 120 } 150)
            Check 'winget has no msstore source' ($t -match '(?m)^winget\b' -and $t -notmatch 'msstore') $t
        }

        Step-Agent 'no flash around requests' {
            $box = @{ Id = 0 }
            Check-NoFlash 'a request dock appearing' { $box.Id = Start-Tool $S 'request_approval' @{ machine = $vm; kind = 'other'; title = "$tag flash check"; reason = 'End-to-end check of the dock appearing.'; waitSeconds = 60 } }
            $d = Click-AgentDock "$tag flash check" $refuse
            Check 'the request dock appears and Refuse is clicked' ($d.Found -and $d.Pressed) $d.Texts
            $t = Get-ReplyText (Wait-AgentReply $S $box.Id 75)
            Check 'the refused request answers the person said no' ($t -match 'said no') $t
        }

        Step-Agent 'offer refused' {
            $since = Get-Date
            $null = Invoke-AgentCall $S 'write_file' @{ machine = $vm; path = "Desktop\Outbox\$tag-ref.txt"; content = "$tag-refused" } 60
            $id = Start-Tool $S 'offer_file' @{ machine = $vm; path = "Desktop\Outbox\$tag-ref.txt"; note = "$tag offer to refuse"; waitSeconds = 60 }
            $d = Click-AgentDock "$tag offer to refuse" $refuse
            Check 'Refuse clicked on the offer' ($d.Found -and $d.Pressed) $d.Texts
            $t = Get-ReplyText (Wait-AgentReply $S $id 75)
            Check 'a refused offer_file answers declined' ($t -match 'refused|declined') $t
            $offer = [regex]::Match($t, '[Oo]ffer ([0-9A-Za-z_-]+)').Groups[1].Value
            $t = if ($offer) { Get-ReplyText (Invoke-AgentCall $S 'offer_status' @{ machine = $vm; offerId = $offer } 30) } else { 'no offer id' }
            Check 'offer_status says declined' ($t -match 'refused|declined') $t
            Start-Sleep -Seconds 3
            $new = @(Get-ChildItem -LiteralPath $dl -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.CreationTime -ge $since -or $_.LastWriteTime -ge $since })
            Check 'nothing new in Downloads\GpuVM after a refusal' ($new.Count -eq 0) (($new | ForEach-Object FullName) -join '; ')
        }

        Step-Agent 'send_file refused' {
            $src = Join-Path ([IO.Path]::GetTempPath()) "$tag-no.txt"
            [IO.File]::WriteAllText($src, "$tag-no")
            $id = Start-Tool $S 'send_file' @{ machine = $vm; hostPath = $src; reason = "$tag send to refuse" }
            $d = Click-AgentDock "$tag send to refuse" $refuse
            Check 'Refuse clicked on send_file' ($d.Found -and $d.Pressed) $d.Texts
            $t = Get-ReplyText (Wait-AgentReply $S $id 75)
            Check 'a refused send_file answers the person said no' ($t -match 'said no') $t
            $t = Get-ReplyText (Invoke-AgentCall $S 'run' @{ machine = $vm; command = "Test-Path (Join-Path `$env:USERPROFILE 'Desktop\Received\$tag-no.txt')" } 60)
            Check 'nothing reaches Desktop\Received after a refusal' ($t -match '(?m)^False\s*$') $t
            Remove-Item -LiteralPath $src -ErrorAction SilentlyContinue
        }

        Step-Agent 'send_file folder' {
            $dir = Join-Path ([IO.Path]::GetTempPath()) "$tag-dir"
            New-Item -ItemType Directory -Force (Join-Path $dir 'sub') | Out-Null
            $files = [ordered]@{ 'a.txt' = "$tag-a"; 'b.txt' = "$tag-b"; 'sub\c.txt' = "$tag-c" }
            foreach ($k in $files.Keys) { [IO.File]::WriteAllText((Join-Path $dir $k), $files[$k]) }
            $id = Start-Tool $S 'send_file' @{ machine = $vm; hostPath = $dir; reason = "$tag send a folder" }
            $d = Click-AgentDock "$tag send a folder" $allow
            Check 'Allow clicked on a folder send_file' ($d.Found -and $d.Pressed) $d.Texts
            $t = Get-ReplyText (Wait-AgentReply $S $id 120)
            Check 'send_file of a folder copies it once allowed' ($t -match 'Copied to') $t
            $inside = [regex]::Match($t, 'Copied to (.+?) in ').Groups[1].Value
            if (-not $inside) { $inside = "Desktop\Received\$tag-dir" }
            $cmd = '$p = ''{0}''; if (-not [IO.Path]::IsPathRooted($p)) {{ $p = Join-Path $env:USERPROFILE $p }}; Get-ChildItem -LiteralPath $p -Recurse -File | ForEach-Object {{ $_.FullName.Substring($p.Length).TrimStart(''\'') + ''='' + (Get-Content -LiteralPath $_.FullName -Raw) }}' -f $inside.Replace("'", "''")
            $t = Get-ReplyText (Invoke-AgentCall $S 'run' @{ machine = $vm; command = $cmd } 60)
            $missing = @($files.Keys | Where-Object { -not $t.Contains("$_=$($files[$_])") })
            Check 'every file of the folder arrives with its content' ($missing.Count -eq 0) $(if ($missing.Count) { "missing: $($missing -join ', ') / $t" } else { $inside })
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }

        Step-Agent 'offer accepted' {
            $null = Invoke-AgentCall $S 'write_file' @{ machine = $vm; path = "Desktop\Outbox\$tag-acc.txt"; content = "$tag-accepted" } 60
            $id = Start-Tool $S 'offer_file' @{ machine = $vm; path = "Desktop\Outbox\$tag-acc.txt"; note = "$tag offer to accept"; waitSeconds = 60 }
            $d = Click-AgentDock "$tag offer to accept" $accept
            Check 'Accept clicked on the offer' ($d.Found -and $d.Pressed) $d.Texts
            $notch = Wait-Notch 'saved in Downloads|guardado en Descargas' 20
            Check 'the notch says the file was saved' ([bool]($notch -and $notch.Text -match 'saved in Downloads|guardado en Descargas')) "$($notch.Text)"
            $t = Get-ReplyText (Wait-AgentReply $S $id 75)
            Check 'the accepted offer answers accepted' ($t -match 'accepted offer') $t
            $file = Wait-For { Get-ChildItem -LiteralPath $dl -File -Recurse -Filter "$tag-acc*" -ErrorAction SilentlyContinue | Select-Object -First 1 } 15
            Check 'the delivered file is in Downloads\GpuVM\<machine>' ([bool]($file -and $file.FullName -like "*\Downloads\GpuVM\$vm\*")) $(if ($file) { $file.FullName } else { 'not found' })
            $zone = if ($file) { (Get-Content -LiteralPath $file.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue) -join ' ' } else { '' }
            Check 'the delivered file is marked as from the internet (ZoneId=3)' ($zone -match 'ZoneId=3') $zone
        }

        Step-Agent 'allow for this task' {
            $id = Start-Tool $S 'request_approval' @{ machine = $vm; kind = 'network'; title = "$tag task grant"; reason = 'End-to-end check of allowing for the task.'; waitSeconds = 60 }
            $dock = Wait-For { Find-AgentDock "$tag task grant" $allow } 20
            Check 'the task request shows a dock' ([bool]$dock) ''
            $picked = $false
            if ($dock) {
                $null = Wait-For { $b = Find-Named $dock.Root $allow ([Windows.Automation.ControlType]::Button); $b -and $b.Current.IsEnabled } 10
                Start-Sleep -Milliseconds 300
                $target = Find-Named $dock.Root "$tag task grant" ([Windows.Automation.ControlType]::Text)
                if (-not $target) { $target = Find-Named $dock.Root "$tag task grant" }
                if (RightClick-Element $target) {
                    $item = Wait-For { Find-AppNamed $forTask } 5
                    if ($item) { $picked = Click-Element $item }
                }
                Check 'Allow for this task is clicked in the dock''s menu' $picked ''
                if (-not $picked) { $null = Click-AgentDock "$tag task grant" $refuse 5 }
            }
            $t = Get-ReplyText (Wait-AgentReply $S $id 75)
            Check 'Allow for this task: the request is allowed' ($t -match 'The person allowed it') $t
            if ($picked) {
                $id = Start-Tool $S 'request_approval' @{ machine = $vm; kind = 'network'; title = "$tag task again"; reason = 'End-to-end check of allowing for the task.'; waitSeconds = 30 }
                $asked = $false; $r = $null
                $deadline = (Get-Date).AddSeconds(40)
                while (-not $r -and (Get-Date) -lt $deadline) {
                    $r = Wait-AgentReply $S $id 1
                    if (-not $r -and -not $asked -and (Find-AgentDock "$tag task again" $refuse)) { $asked = $true; $null = Click-AgentDock "$tag task again" $refuse 5 }
                }
                Check 'a second request of the same kind asks nothing' (-not $asked) ''
                Check 'a second request of the same kind is allowed' ((Get-ReplyText $r) -match 'The person allowed it') (Get-ReplyText $r)
            }
        }

        Step-Agent 'click right and ui_invoke' {
            $null = Invoke-AgentCall $S 'run' @{ machine = $vm; command = 'Start-Process notepad' } 30
            $null = Wait-AgentWindow $S $vm $notepad
            $null = Invoke-AgentCall $S 'key' @{ machine = $vm; keys = 'win+up'; delayMs = 1000 } 30
            $a = Get-AgentShot $S $vm
            $t = Get-ReplyText (Invoke-AgentCall $S 'click' @{ machine = $vm; x = [int]($a.W / 2); y = [int]($a.H / 2); button = 'right'; delayMs = 800 } 60)
            $b = Get-AgentShot $S $vm
            # The menu opens below and right of the click: its gray box covers that part of the blank page.
            $changed = Get-ChangedShare $a.Image $b.Image 0.51 0.51 0.12 0.2
            Check 'click button right opens a context menu' ($t -match '^Done' -and $changed -ge 0.3) ("{0}; {1:P0} of the box below the click changed" -f $t, $changed)
            $tree = Get-ReplyText (Invoke-AgentCall $S 'ui_tree' @{ machine = $vm; interactiveOnly = $false; maxNodes = 120 } 30)
            Check 'ui_tree lists the open context menu' ($tree -match '(?m)^\S+ (menu|menuitem) "(Undo|Deshacer|Cut|Cortar|Select All|Seleccionar todo|Paste|Pegar)') (($tree -split "`n" | Select-Object -First 6) -join ' / ')
            $null = Invoke-AgentCall $S 'key' @{ machine = $vm; keys = 'escape'; delayMs = 500 } 30
            $tree = Get-ReplyText (Invoke-AgentCall $S 'ui_tree' @{ machine = $vm; maxNodes = 150 } 30)
            $help = Get-TreeId $tree '(Help|Ayuda)'
            $t = if ($help) { Get-ReplyText (Invoke-AgentCall $S 'ui_invoke' @{ machine = $vm; id = $help; action = 'expand' } 60) } else { 'no Help menu in ui_tree' }
            $tree = Get-ReplyText (Invoke-AgentCall $S 'ui_tree' @{ machine = $vm; interactiveOnly = $false; maxNodes = 200 } 30)
            $about = Get-TreeId $tree '(About Notepad|Acerca del? Bloc de notas)'
            $t = if ($about) { Get-ReplyText (Invoke-AgentCall $S 'ui_invoke' @{ machine = $vm; id = $about; action = 'invoke' } 60) } else { "no About item: $t" }
            $dlg = Wait-AgentWindow $S $vm '(?m)^\S+ (window|pane) "(About Notepad|Acerca del? Bloc de notas)"' 15
            Check 'ui_invoke invoke on a Notepad menu opens its dialog' ($t -match '^Done' -and $dlg -match 'About Notepad|Acerca del? Bloc de notas') "$t / $(($dlg -split "`n" | Select-Object -First 3) -join ' / ')"
            $null = Invoke-AgentCall $S 'key' @{ machine = $vm; keys = 'escape'; delayMs = 800 } 30
            $t = Wait-AgentWindow $S $vm "^(?![\s\S]*(About Notepad|Acerca del? Bloc de notas))" 10
            Check 'the dialog closes' ($t -notmatch 'About Notepad|Acerca del? Bloc de notas') (($t -split "`n" | Select-Object -First 2) -join ' / ')
            & $closeApps
        }

        Step-Agent 'key repeat' {
            $null = Invoke-AgentCall $S 'write_file' @{ machine = $vm; path = "Desktop\$tag-rep.txt"; content = 'abcdef' } 60
            $null = Invoke-AgentCall $S 'run' @{ machine = $vm; command = "Start-Process notepad -ArgumentList '$($st.Home)\Desktop\$tag-rep.txt'" } 30
            $null = Wait-AgentWindow $S $vm "$tag-rep"
            $null = Invoke-AgentCall $S 'key' @{ machine = $vm; keys = 'ctrl+end' } 30
            $t = Get-ReplyText (Invoke-AgentCall $S 'key' @{ machine = $vm; keys = 'backspace'; repeat = 3; delayMs = 300 } 30)
            $null = Invoke-AgentCall $S 'key' @{ machine = $vm; keys = (Get-SaveKey $S $vm); delayMs = 1200 } 30
            $r = Get-ReplyText (Invoke-AgentCall $S 'read_file' @{ machine = $vm; path = "Desktop\$tag-rep.txt" } 60)
            Check 'key with repeat 3 presses it three times' ($t -match '^Done' -and $r -match '\nabc\s*$') $r
            & $closeApps
        }

        Step-Agent 'act click and scroll' {
            $lines = @(1..60 | ForEach-Object { '@' * 70 }) + @(1..300 | ForEach-Object { '' })
            $null = Invoke-AgentCall $S 'write_file' @{ machine = $vm; path = "Desktop\$tag-long.txt"; content = ($lines -join "`r`n") } 60
            $null = Invoke-AgentCall $S 'run' @{ machine = $vm; command = "Start-Process notepad -ArgumentList '$($st.Home)\Desktop\$tag-long.txt'" } 30
            $null = Wait-AgentWindow $S $vm "$tag-long"
            $null = Invoke-AgentCall $S 'key' @{ machine = $vm; keys = 'win+up'; delayMs = 1000 } 30
            $a = Get-AgentShot $S $vm
            $x = [int]($a.W / 2); $y = [int]($a.H / 2)
            $t = Get-ReplyText (Invoke-AgentCall $S 'act' @{ machine = $vm; delayMs = 800; actions = @(@{ type = 'click'; x = $x; y = $y }, @{ type = 'scroll'; x = $x; y = $y; dy = 30 }) } 60)
            $b = Get-AgentShot $S $vm
            $before = Get-InkShare $a.Image 0.1 0.25 0.4 0.35
            $after = Get-InkShare $b.Image 0.1 0.25 0.4 0.35
            Check 'act with click and scroll scrolls the text away' ($t -match 'Done 2 of 2' -and $before -gt 0.02 -and $after -lt $before / 2) ("{0}; text before {1:P1}, after {2:P1}" -f $t, $before, $after)
            & $closeApps
        }

        Step-Agent 'double click' {
            $null = Invoke-AgentCall $S 'write_file' @{ machine = $vm; path = "Desktop\$tag-dbl.txt"; content = "$tag-dbl" } 60
            $null = Invoke-AgentCall $S 'key' @{ machine = $vm; keys = 'win+d'; delayMs = 1500 } 30
            $null = Get-AgentShot $S $vm
            $tree = Get-ReplyText (Invoke-AgentCall $S 'ui_tree' @{ machine = $vm; interactiveOnly = $false; maxNodes = 400 } 30)
            $c = Get-TreeCentre $tree "$tag-dbl"
            if ($c) {
                $t = Get-ReplyText (Invoke-AgentCall $S 'click' @{ machine = $vm; x = $c[0]; y = $c[1]; count = 2; delayMs = 1500 } 60)
                $w = Wait-AgentWindow $S $vm "$tag-dbl[^\n]*($notepad)"
                Check 'click count 2 on a desktop file opens it' ($t -match '^Done' -and $w -match "$tag-dbl[^\n]*($notepad)") (($w -split "`n" | Select-Object -First 2) -join ' / ')
            } else { Check 'click count 2 on a desktop file opens it' $false "the file isn't in the desktop's ui_tree" }
            & $closeApps
        }

        Step-Agent 'drag in Paint' {
            $null = Invoke-AgentCall $S 'run' @{ machine = $vm; command = 'Start-Process mspaint' } 30
            $null = Wait-AgentWindow $S $vm 'Paint'
            $null = Invoke-AgentCall $S 'key' @{ machine = $vm; keys = 'win+up'; delayMs = 1000 } 30
            $a = Get-AgentShot $S $vm
            $t = Get-ReplyText (Invoke-AgentCall $S 'drag' @{ machine = $vm; x = [int]($a.W * 0.12); y = [int]($a.H * 0.36); toX = [int]($a.W * 0.28); toY = [int]($a.H * 0.36) } 60)
            $b = Get-AgentShot $S $vm
            $before = Get-DarkShare $a.Image 0.13 0.35 0.14 0.02
            $after = Get-DarkShare $b.Image 0.13 0.35 0.14 0.02
            Check 'drag with toX/toY draws a line in Paint' ($t -match '^Done' -and $after -gt $before + 0.02) ("{0}; dark before {1:P1}, after {2:P1}" -f $t, $before, $after)
            $path = [Collections.Generic.List[object]]::new()
            for ($i = 0; $i -le 8; $i++) { $path.Add(@([int]($b.W * (0.12 + 0.02 * $i)), [int]($b.H * $(if ($i % 2) { 0.50 } else { 0.42 })))) }
            $t = Get-ReplyText (Invoke-AgentCall $S 'drag' @{ machine = $vm; path = $path } 60)
            $c = Get-AgentShot $S $vm
            $before = Get-DarkShare $b.Image 0.12 0.41 0.16 0.10
            $after = Get-DarkShare $c.Image 0.12 0.41 0.16 0.10
            Check 'drag with path draws a zigzag in Paint' ($t -match '^Done' -and $after -gt $before + 0.008) ("{0}; dark before {1:P1}, after {2:P1}" -f $t, $before, $after)
            & $closeApps
        }

        Step-Agent 'run cmd with cwd' {
            $t = Get-ReplyText (Invoke-AgentCall $S 'run' @{ machine = $vm; command = 'cd'; shell = 'cmd'; cwd = 'C:\Windows\System32' } 60)
            Check 'run shell cmd starts in cwd' ($t -match 'Exit code 0' -and $t -match '(?mi)^C:\\Windows\\System32\s*$') $t
        }

        Step-Agent 'png through files' {
            $bmp = [Drawing.Bitmap]::new(24, 16)
            $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::FromArgb(200, 30, 60)); $g.Dispose()
            $ms = [IO.MemoryStream]::new(); $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
            $png = $ms.ToArray(); $ms.Dispose()
            $t = Get-ReplyText (Invoke-AgentCall $S 'write_file' @{ machine = $vm; path = "Desktop\$tag.png"; content = [Convert]::ToBase64String($png); encoding = 'base64' } 60)
            Check 'write_file with base64 writes the exact bytes' ($t -match "Wrote $($png.Length) bytes") $t
            $r = Invoke-AgentCall $S 'read_file' @{ machine = $vm; path = "Desktop\$tag.png" } 60
            $img = Get-ReplyImage $r
            $same = $img -and $img.mimeType -eq 'image/png' -and [Convert]::FromBase64String($img.data).Length -eq $png.Length
            Check 'read_file of a .png returns the image' ([bool]$same) "$($img.mimeType) / $(Get-ReplyText $r)"
        }

        Step-Agent 'screenshot parameters' {
            $shot = Get-AgentShot $S $vm @{ maxWidth = 640 }
            Check 'screenshot maxWidth 640 is 640 wide' ($shot.W -eq 640) $shot.Text
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $shot = Get-AgentShot $S $vm @{ delayMs = 2000 }
            $sw.Stop()
            Check 'screenshot delayMs 2000 waits about 2 s' ([bool]$shot.Image -and $sw.ElapsedMilliseconds -ge 1900) "$($sw.ElapsedMilliseconds) ms"
            $null = Get-AgentShot $S $vm
        }

        Step-Agent 'recording' {
            $videos = Join-Path ([Environment]::GetFolderPath('MyVideos')) "GpuVM\$vm"
            $saved = @(Get-ChildItem -LiteralPath $videos -File -Filter *.mp4 -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $suiteStart })
            $viewer = Join-Path $env:USERPROFILE 'AppData\LocalLow\GpuVM\Viewer'
            # The recording may have started in an earlier suite on the same machine. The viewer holds the file it records
            # into (a .part in its Captures) locked, so NTFS shows neither its size nor its time changing: a locked .part
            # created since this viewer started is the recording in progress.
            $since = (Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Sort-Object StartTime | Select-Object -First 1).StartTime
            $writing = @(foreach ($d in 'Captures', 'Temp') {
                Get-ChildItem -LiteralPath (Join-Path $viewer $d) -File -Filter *.part -ErrorAction SilentlyContinue | Where-Object {
                    $f = $_; $held = $false
                    try { [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite, Delete').Dispose() } catch { $held = $true }
                    $held -and $since -and $f.CreationTime -ge $since.AddSeconds(-5)
                }
            })
            $detail = if ($saved.Count) { "saved: $($saved[0].FullName)" } elseif ($writing.Count) { "being written: $($writing[0].FullName) (since $($writing[0].CreationTime.ToString('HH:mm:ss')))" } else { "nothing in $videos since $($suiteStart.ToString('HH:mm:ss')) and no capture held open by the viewer" }
            Check 'a recording of the agent''s work is saved or being written for the machine' ($saved.Count -gt 0 -or $writing.Count -gt 0) $detail
        }
    }
    finally {
        try { & $closeApps } catch { }
        if ($S.PSObject.Properties.Name -contains 'Pending' -and $S.Pending) {
            $null = $S.Pending.Wait(30000)
            $S.Pending = $null
        }
    }
}
