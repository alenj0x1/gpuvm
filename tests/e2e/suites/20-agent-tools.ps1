# Every MCP tool against the real machine: what each one answers and what it really did in the machine or on this PC.

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

# Share of dark pixels in a box given as fractions of a PNG screenshot.
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

function Invoke-AgentDock([string]$Pattern, [string]$Button, [double]$Seconds = 20) {
    $res = [pscustomobject]@{ Found = $false; Pressed = $false; Gone = $false; Texts = '' }
    $dock = Wait-For { Find-AgentDock $Pattern $Button } $Seconds
    if (-not $dock) { return $res }
    $res.Found = $true; $res.Texts = $dock.Texts
    $deadline = (Get-Date).AddSeconds(10)
    while (-not $res.Pressed -and (Get-Date) -lt $deadline) {
        $b = Find-Named $dock.Root $Button ([Windows.Automation.ControlType]::Button)
        if ($b -and $b.Current.IsEnabled) { try { $res.Pressed = [bool](Invoke-Element $b) } catch { } }
        if (-not $res.Pressed) { Start-Sleep -Milliseconds 250 }
    }
    $res.Gone = [bool](Wait-For { -not (Find-AgentDock $Pattern $Button) } 10)
    $res
}

function Wait-AgentWindow($Session, [string]$Machine, [string]$Pattern, [double]$Seconds = 25) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $t = Get-ReplyText (Invoke-AgentCall $Session 'ui_tree' @{ machine = $Machine; interactiveOnly = $false; maxNodes = 5 } 30)
        if ($t -match $Pattern) { return $t }
        Start-Sleep -Milliseconds 700
    } while ((Get-Date) -lt $deadline)
    $t
}

function Step-Agent([string]$Name, [scriptblock]$Body) {
    try { & $Body } catch { Check "$Name ran to the end" $false $_.Exception.Message }
}

function Test-Suite($Ctx) {
    $vm = Use-Machine $Ctx
    $S = $Ctx.Mcp
    $tag = "e2e$(Get-Random -Minimum 100000 -Maximum 999999)"
    $st = @{ W = 1280; H = 800; Home = 'C:\Users\agent' }
    $allow = '^\W*(Allow|Permitir)\W*$'
    $refuse = '^\W*(Refuse|Rechazar)\W*$'
    $accept = '^\W*(Accept|Aceptar)\W*$'
    $back = '^\W*(Return to agent|Volver al agente)\W*$'
    try {
        Step-Agent 'machines' {
            $t = Get-ReplyText (Invoke-AgentCall $S 'list_templates' @{} 30)
            Check 'list_templates lists the template' ($t -match [regex]::Escape($Ctx.Template)) $t
            $t = Get-ReplyText (Invoke-AgentCall $S 'list_machines' @{} 30)
            Check 'list_machines shows the machine taken by this session' ($t -match "$([regex]::Escape($vm))[^\n]*taken by you") $t
        }

        Step-Agent 'screenshot' {
            $r = Invoke-AgentCall $S 'screenshot' @{ machine = $vm } 60
            $img = Get-ReplyImage $r
            Check 'screenshot returns an image with data' ([bool]($img -and $img.data.Length -gt 1000 -and $img.mimeType -eq 'image/webp')) "$($img.mimeType), $($img.data.Length) base64 chars"
            $t = Get-ReplyText $r
            $m = [regex]::Match($t, '(\d+)x(\d+) \(desktop')
            Check 'screenshot says its size' ($m.Success) $t
            if ($m.Success) { $st.W = [int]$m.Groups[1].Value; $st.H = [int]$m.Groups[2].Value }
            $z = Invoke-AgentCall $S 'screenshot' @{ machine = $vm; zoom = @(0, 0, [int]($st.W / 4), [int]($st.H / 4)) } 60
            Check 'screenshot zoom returns a zoomed image' ([bool]((Get-ReplyImage $z) -and (Get-ReplyText $z) -match 'zoom of desktop')) (Get-ReplyText $z)
            $p = Get-AgentShot $S $vm
            $png = $p.Image -and $p.Image.mimeType -eq 'image/png' -and ([Convert]::FromBase64String($p.Image.data)[1..3] -join ',') -eq '80,78,71'
            Check 'screenshot format png is a PNG' ([bool]$png) "$($p.Image.mimeType)"
        }

        Step-Agent 'run' {
            $t = Get-ReplyText (Invoke-AgentCall $S 'run' @{ machine = $vm; command = "Write-Output '$tag-out'; exit 3"; intent = 'Running a command' } 90)
            Check 'run returns the command''s output' ($t -match "$tag-out") $t
            Check 'run reports the exit code' ($t -match 'Exit code 3') $t
            $t = Get-ReplyText (Invoke-AgentCall $S 'run' @{ machine = $vm; command = '$env:USERPROFILE' } 60)
            $h = [regex]::Match($t, '--- stdout ---\n([^\r\n]+)')
            if ($h.Success) { $st.Home = $h.Groups[1].Value.Trim() }
            $t = Get-ReplyText (Invoke-AgentCall $S 'run' @{ machine = $vm; command = "Start-Sleep 2; Write-Output '$tag-bg'"; background = $true } 30)
            $id = [regex]::Match($t, 'run-\d+').Value
            Check 'run background answers at once with a run id' ([bool]$id) $t
            if ($id) {
                $t = Get-ReplyText (Invoke-AgentCall $S 'run_result' @{ machine = $vm; runId = $id; waitSeconds = 60 } 75)
                Check 'run_result gives the background output and exit code' ($t -match "$tag-bg" -and $t -match 'Exit code 0') $t
            }
        }

        Step-Agent 'files' {
            $content = "$tag-content ñ"
            $t = Get-ReplyText (Invoke-AgentCall $S 'write_file' @{ machine = $vm; path = "Desktop\$tag.txt"; content = $content } 60)
            Check 'write_file writes the file' ($t -match 'Wrote \d+ bytes') $t
            $t = Get-ReplyText (Invoke-AgentCall $S 'read_file' @{ machine = $vm; path = "Desktop\$tag.txt" } 60)
            Check 'read_file reads back what write_file wrote' ($t.Contains($content)) $t
        }

        Step-Agent 'notepad' {
            $null = Invoke-AgentCall $S 'run' @{ machine = $vm; command = 'notepad.exe'; shell = 'none'; background = $true; intent = 'Opening Notepad' } 30
            $t = Wait-AgentWindow $S $vm 'Notepad|Bloc de notas'
            if ($t -notmatch 'Notepad|Bloc de notas') {
                $null = Invoke-AgentCall $S 'run' @{ machine = $vm; command = "`$w = New-Object -ComObject WScript.Shell; foreach (`$n in 'Bloc de notas', 'Notepad') { if (`$w.AppActivate(`$n)) { break } }" } 30
                $t = Wait-AgentWindow $S $vm 'Notepad|Bloc de notas'
            }
            if ($t -notmatch 'Notepad|Bloc de notas') {
                $diag = Get-ReplyText (Invoke-AgentCall $S 'run' @{ machine = $vm; command = 'Get-Process notepad -ErrorAction SilentlyContinue | Select-Object Id, MainWindowTitle, SessionId | Format-Table -AutoSize | Out-String' } 30)
                Write-Host "     notepad in the machine: $diag"
            }
            Check 'Notepad started with run is in front' ($t -match 'Notepad|Bloc de notas') $t
            $null = Invoke-AgentCall $S 'type' @{ machine = $vm; text = "$tag-one"; intent = 'Typing' } 60
            $t = Get-ReplyText (Invoke-AgentCall $S 'key' @{ machine = $vm; keys = 'ctrl+a'; delayMs = 300 } 60)
            Check 'key answers' ($t -match '^Done') $t
            $t = Get-ReplyText (Invoke-AgentCall $S 'type' @{ machine = $vm; text = "$tag-typed"; delayMs = 300 } 60)
            Check 'type answers' ($t -match '^Done') $t
            $file = "$($st.Home)\Desktop\$tag-notepad.txt"
            $t = Get-ReplyText (Invoke-AgentCall $S 'act' @{ machine = $vm; intent = 'Saving'; actions = @(
                @{ type = 'key'; keys = 'ctrl+s' }, @{ type = 'wait'; ms = 2000 }, @{ type = 'type'; text = $file },
                @{ type = 'key'; keys = 'enter' }, @{ type = 'wait'; ms = 1500 }) } 90)
            Check 'act runs several actions in one call' ($t -match 'Done 5 of 5 actions') $t
            $t = Get-ReplyText (Invoke-AgentCall $S 'read_file' @{ machine = $vm; path = "Desktop\$tag-notepad.txt" } 60)
            Check 'the typed text reached Notepad (saved through act)' ($t -match "$tag-typed") $t
            Check 'key ctrl+a selected the earlier text (typing replaced it)' ($t -match "$tag-typed" -and $t -notmatch "$tag-one") $t
            $tree = Get-ReplyText (Invoke-AgentCall $S 'ui_tree' @{ machine = $vm; interactiveOnly = $false; maxNodes = 80 } 30)
            Check 'ui_tree finds Notepad and its document' ($tree -match 'Notepad|Bloc de notas' -and $tree -match "$tag-notepad") (($tree -split "`n" | Select-Object -First 4) -join ' / ')
            $edit = [regex]::Match($tree, '(?m)^(\S+) (edit|document) "[^"\n]*"[^\n]*setValue')
            Check 'ui_tree lists Notepad''s text box' ($edit.Success) ''
            if ($edit.Success) {
                $t = Get-ReplyText (Invoke-AgentCall $S 'ui_invoke' @{ machine = $vm; id = $edit.Groups[1].Value; action = 'setValue'; value = "$tag-set"; intent = 'Setting the text' } 60)
                Check 'ui_invoke answers' ($t -match '^Done') $t
                $null = Invoke-AgentCall $S 'act' @{ machine = $vm; actions = @(@{ type = 'key'; keys = 'ctrl+end' }, @{ type = 'type'; text = '!' }, @{ type = 'key'; keys = 'ctrl+s' }, @{ type = 'wait'; ms = 1500 }) } 60
                $t = Get-ReplyText (Invoke-AgentCall $S 'read_file' @{ machine = $vm; path = "Desktop\$tag-notepad.txt" } 60)
                Check 'ui_invoke setValue changed Notepad''s text' ($t -match "$tag-set") $t
            }
            $null = Invoke-AgentCall $S 'run' @{ machine = $vm; command = 'Stop-Process -Name notepad -Force -ErrorAction SilentlyContinue' } 60
        }

        Step-Agent 'scroll' {
            $lines = @(1..60 | ForEach-Object { '@' * 70 }) + @(1..300 | ForEach-Object { '' })
            $null = Invoke-AgentCall $S 'write_file' @{ machine = $vm; path = "Desktop\$tag-long.txt"; content = ($lines -join "`r`n") } 60
            $null = Invoke-AgentCall $S 'run' @{ machine = $vm; command = 'notepad.exe'; shell = 'none'; args = @("$($st.Home)\Desktop\$tag-long.txt"); background = $true } 30
            $null = Wait-AgentWindow $S $vm "$tag-long"
            $null = Invoke-AgentCall $S 'key' @{ machine = $vm; keys = 'win+up'; delayMs = 1000 } 30
            $a = Get-AgentShot $S $vm
            $t = Get-ReplyText (Invoke-AgentCall $S 'scroll' @{ machine = $vm; x = [int]($a.W / 2); y = [int]($a.H / 2); dy = 30; delayMs = 800; intent = 'Scrolling' } 60)
            $b = Get-AgentShot $S $vm
            $before = Get-DarkShare $a.Image 0.1 0.25 0.4 0.35
            $after = Get-DarkShare $b.Image 0.1 0.25 0.4 0.35
            Check 'scroll moved the text out of sight' ($t -match '^Done' -and $before -gt 0.02 -and $after -lt $before / 2) ("{0}; dark before {1:P1}, after {2:P1}" -f $t, $before, $after)
            $null = Invoke-AgentCall $S 'run' @{ machine = $vm; command = 'Stop-Process -Name notepad -Force -ErrorAction SilentlyContinue' } 60
        }

        Step-Agent 'paint' {
            $null = Invoke-AgentCall $S 'run' @{ machine = $vm; command = 'mspaint.exe'; shell = 'none'; background = $true; intent = 'Opening Paint' } 30
            $t = Wait-AgentWindow $S $vm 'Paint'
            Check 'Paint started with run is in front' ($t -match 'Paint') $t
            $null = Invoke-AgentCall $S 'key' @{ machine = $vm; keys = 'win+up'; delayMs = 1000 } 30
            $a = Get-AgentShot $S $vm
            $strokes = [Collections.Generic.List[object]]::new()
            foreach ($f in 0.34, 0.38, 0.42, 0.46) {
                $line = [Collections.Generic.List[object]]::new()
                $line.Add(@([int]($a.W * 0.12), [int]($a.H * $f))); $line.Add(@([int]($a.W * 0.28), [int]($a.H * $f)))
                $strokes.Add($line)
            }
            $t = Get-ReplyText (Invoke-AgentCall $S 'drag' @{ machine = $vm; strokes = $strokes; intent = 'Drawing lines' } 60)
            $b = Get-AgentShot $S $vm
            $before = Get-DarkShare $a.Image 0.1 0.3 0.2 0.2
            $after = Get-DarkShare $b.Image 0.1 0.3 0.2 0.2
            Check 'drag with strokes draws in Paint' ($t -match '^Done' -and $after -gt $before + 0.005) ("{0}; dark before {1:P1}, after {2:P1}" -f $t, $before, $after)
            $r = Invoke-AgentCall $S 'click' @{ machine = $vm; x = [int]($a.W * 0.2); y = [int]($a.H * 0.55); screenshotAfter = $true; intent = 'Clicking' } 60
            Check 'click with screenshotAfter returns a fresh screenshot' ([bool]((Get-ReplyText $r) -match '^Done' -and (Get-ReplyImage $r))) (Get-ReplyText $r)
            $null = Invoke-AgentCall $S 'run' @{ machine = $vm; command = 'Stop-Process -Name mspaint -Force -ErrorAction SilentlyContinue' } 60
        }

        Step-Agent 'approval' {
            $id = Start-Tool $S 'request_approval' @{ machine = $vm; kind = 'other'; title = "$tag allow me"; reason = 'End-to-end check of approvals.'; waitSeconds = 60 }
            $d = Invoke-AgentDock "$tag allow me" $allow
            Check 'request_approval shows a dock over the picture' $d.Found $d.Texts
            $t = Get-ReplyText (Wait-AgentReply $S $id 75)
            Check 'Allow in the dock: the tool answers allowed' ($t -match 'The person allowed it') $t
            Check 'the answered request leaves the dock' $d.Gone ''
            $id = Start-Tool $S 'request_approval' @{ machine = $vm; kind = 'other'; title = "$tag refuse me"; reason = 'End-to-end check of approvals.'; waitSeconds = 60 }
            $d = Invoke-AgentDock "$tag refuse me" $refuse
            Check 'a second request_approval shows a dock' $d.Found $d.Texts
            $t = Get-ReplyText (Wait-AgentReply $S $id 75)
            Check 'Refuse in the dock: the tool answers the person said no' ($t -match 'The person said no') $t
            Check 'the refused request leaves the dock' $d.Gone ''
        }

        Step-Agent 'send_file' {
            $src = Join-Path ([IO.Path]::GetTempPath()) "$tag-send.txt"
            Set-Content -LiteralPath $src -Value "$tag-sent" -Encoding utf8 -NoNewline
            $id = Start-Tool $S 'send_file' @{ machine = $vm; hostPath = $src; reason = 'End-to-end check of send_file.' }
            $d = Invoke-AgentDock "$tag-send" $allow
            Check 'send_file asks in the dock' $d.Found $d.Texts
            $t = Get-ReplyText (Wait-AgentReply $S $id 90)
            Check 'send_file copies the file once allowed' ($t -match 'Copied to .* \(\d+ bytes, checked\)') $t
            $t = Get-ReplyText (Invoke-AgentCall $S 'read_file' @{ machine = $vm; path = "Desktop\Received\$tag-send.txt" } 60)
            Check 'the sent file is in Desktop\Received with its content' ($t -match "$tag-sent") $t
            Remove-Item -LiteralPath $src -ErrorAction SilentlyContinue
        }

        Step-Agent 'offer_file' {
            $dl = Join-Path $env:USERPROFILE 'Downloads\GpuVM'
            $since = (Get-Date).AddSeconds(-2)
            $null = Invoke-AgentCall $S 'write_file' @{ machine = $vm; path = "Desktop\Outbox\$tag-offer.txt"; content = "$tag-offered" } 60
            $id = Start-Tool $S 'offer_file' @{ machine = $vm; path = "Desktop\Outbox\$tag-offer.txt"; note = "$tag offer for the e2e suite"; waitSeconds = 60 }
            $d = Invoke-AgentDock "$tag offer" $accept
            Check 'offer_file asks in the dock' $d.Found $d.Texts
            $t = Get-ReplyText (Wait-AgentReply $S $id 75)
            Check 'Accept in the dock: offer_file answers accepted' ($t -match 'accepted offer') $t
            Check 'the accepted offer leaves the dock' $d.Gone ''
            $offer = [regex]::Match($t, '[Oo]ffer ([^\s;()]+)').Groups[1].Value
            if ($offer) {
                $t = Get-ReplyText (Invoke-AgentCall $S 'offer_status' @{ machine = $vm; offerId = $offer } 30)
                Check 'offer_status says accepted' ($t -match 'accepted') $t
            } else { Check 'offer_status says accepted' $false 'no offer id' }
            $file = Wait-For {
                Get-ChildItem -LiteralPath $dl -File -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.CreationTime -ge $since -or $_.LastWriteTime -ge $since } |
                    Sort-Object { [Math]::Max($_.CreationTime.Ticks, $_.LastWriteTime.Ticks) } -Descending | Select-Object -First 1
            } 20
            $body = if ($file) { Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue } else { '' }
            Check 'the delivered file lands in Downloads\GpuVM' ([bool]($file -and $body -match "$tag-offered")) $(if ($file) { $file.FullName } else { "nothing new in $dl" })
        }

        Step-Agent 'restore points' {
            $null = Invoke-AgentCall $S 'write_file' @{ machine = $vm; path = "Desktop\$tag-before.txt"; content = 'before' } 60
            $r = Invoke-AgentCall $S 'restore_point_create' @{ machine = $vm; label = $tag } 420
            $t = Get-ReplyText $r
            if ((Test-ReplyError $r) -and $t -match 'disposable') {
                Check 'restore_point_create refuses a disposable machine' $true $t
                $r = Invoke-AgentCall $S 'restore_point_revert' @{ machine = $vm; point = $tag; reason = 'End-to-end check.' } 60
                $t = Get-ReplyText $r
                Check 'restore_point_revert refuses a disposable machine' ((Test-ReplyError $r) -and $t -match 'disposable') $t
            } else {
                Check 'restore_point_create saves a restore point' ($t -match 'Restore point .* saved') $t
                $null = Invoke-AgentCall $S 'write_file' @{ machine = $vm; path = "Desktop\$tag-after.txt"; content = 'after' } 60
                $id = Start-Tool $S 'restore_point_revert' @{ machine = $vm; point = $tag; reason = "$tag revert check" }
                $d = Invoke-AgentDock "$tag" $allow 30
                Check 'restore_point_revert asks in the dock' $d.Found $d.Texts
                $t = Get-ReplyText (Wait-AgentReply $S $id 420)
                Check 'restore_point_revert goes back once allowed' ($t -match 'is back at') $t
                $after = Invoke-AgentCall $S 'read_file' @{ machine = $vm; path = "Desktop\$tag-after.txt" } 60
                $before = Get-ReplyText (Invoke-AgentCall $S 'read_file' @{ machine = $vm; path = "Desktop\$tag-before.txt" } 60)
                Check 'after the revert the later file is gone and the earlier one is there' ((Test-ReplyError $after) -and $before -match 'before') "$(Get-ReplyText $after) / $before"
            }
        }

        Step-Agent 'request_human' {
            $msg = "$tag please look at the machine"
            $t = Get-ReplyText (Invoke-AgentCall $S 'request_human' @{ machine = $vm; message = $msg } 30)
            Check 'request_human answers that the agent is paused' ($t -match 'Asked the person') $t
            $dock = Wait-For { Find-AgentDock $tag $back } 15
            $notch = Get-Notch
            Check 'the dock or notch shows the agent''s message' ([bool]($dock -or ($notch -and $notch.Text -match $tag))) "dock: $($dock.Texts) / notch: $($notch.Text)"
            Shot 'tools-request-human'
            $t = Get-ReplyText (Invoke-AgentCall $S 'list_machines' @{} 30)
            Check 'list_machines shows the machine waiting for the person' ($t -match "$([regex]::Escape($vm))[^\n]*waiting for the person") $t
            $t = Get-ReplyText (Invoke-AgentCall $S 'cancel_request' @{ machine = $vm } 30)
            Check 'cancel_request withdraws the request' ($t -match 'Withdrew your request') $t
            Check 'the withdrawn request leaves the dock' ([bool](Wait-For { -not (Find-AgentDock $tag $back) } 10)) ''
            $t = Get-ReplyText (Invoke-AgentCall $S 'list_machines' @{} 30)
            Check 'the machine is no longer paused' ($t -notmatch "$([regex]::Escape($vm))[^\n]*paused") $t
        }

        Step-Agent 'wait_for_person' {
            $t = Get-ReplyText (Invoke-AgentCall $S 'wait_for_person' @{ machine = $vm; waitSeconds = 10 } 15)
            Check 'wait_for_person on a machine not paused answers at once' ($t -match "isn't paused") $t
        }

        Step-Agent 'release and take' {
            $t = Get-ReplyText (Invoke-AgentCall $S 'release_machine' @{ machine = $vm } 30)
            Check 'release_machine releases it' ($t -match "Released $([regex]::Escape($vm))") $t
            $t = Get-ReplyText (Invoke-AgentCall $S 'list_machines' @{} 30)
            Check 'the released machine is no longer taken by this session' ($t -notmatch "$([regex]::Escape($vm))[^\n]*taken by you") $t
            $id = Start-Tool $S 'take_machine' @{ machine = $vm; waitSeconds = 120; task = 'End-to-end suite' }
            $asked = $false; $r = $null
            $deadline = (Get-Date).AddSeconds(150)
            while (-not $r -and (Get-Date) -lt $deadline) {
                $r = Wait-AgentReply $S $id 1
                if (-not $r -and -not $asked -and (Find-AgentDock ([regex]::Escape($vm)) $allow)) {
                    $asked = $true
                    $null = Invoke-AgentDock ([regex]::Escape($vm)) $allow 5
                }
            }
            Check 'taking back its own disposable machine asks no approval' (-not $asked) ''
            $t = Get-ReplyText $r
            Check 'take_machine takes it again' ($t -match "You have $([regex]::Escape($vm))") $t
        }
    }
    finally {
        if ($S.PSObject.Properties.Name -contains 'Pending' -and $S.Pending) {
            $null = $S.Pending.Wait(30000)
            $S.Pending = $null
        }
    }
}
