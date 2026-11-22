# What the person sees over the picture while an agent works: the viewer in front, the status notch (intent, take
# control, recording), the agent's cursor without Windows' own behind it, the side panel, and giving the machine back.
function Test-Suite($Ctx) {
    $vm = Use-Machine $Ctx
    $s = Screen
    $cx = [int]($s.Width / 2); $cy = [int]($s.Height / 2)
    Start-Sleep -Seconds 2
    Check 'the picture is in front of the other windows' ([E2E]::ProcessNameAt($cx, $cy) -eq 'GpuVMViewer') "at the center: $([E2E]::ProcessNameAt($cx, $cy))"
    Shot 'overlays-1-opened'

    $null = Invoke-Tool $Ctx.Mcp 'screenshot' @{ machine = $vm; maxWidth = 640 }
    $null = Invoke-Tool $Ctx.Mcp 'click' @{ machine = $vm; x = 320; y = 200; intent = 'Clicking the desktop' }
    $pending = Start-Tool $Ctx.Mcp 'run' @{ machine = $vm; command = 'Start-Sleep -Seconds 8'; intent = 'Checking the notch' }
    $n = Wait-Notch 'Checking the notch' 7
    Check 'notch shows the agent''s intent' ($n -and $n.Text -match 'Checking the notch') "text: $($n.Text)"
    Check-Drawn 'agent notch' $n
    # The agent clicked at (320, 200) of a 640-wide screenshot: the same spot of the full-screen picture.
    $px = [int](320 * $s.Width / 640); $py = [int](200 * $s.Width / 640)
    $black = [E2E]::Black($px - 4, $py - 4, 24, 30)
    $crop = Grab ($px - 40) ($py - 40) 120 110; $crop.Save((Join-Path $Ctx.Out 'overlays-cursor.png')); $crop.Dispose()
    Check 'only the agent''s cursor shows where it clicked (no Windows cursor behind it)' ($black -lt 6) "$black black pixels at the click"
    Check 'the agent''s cursor is drawn' ([bool](Get-AppWindows | Where-Object { (Get-Texts (Get-Element $_.Handle)) -match 'E2e' })) ''
    Shot 'overlays-2-agent'
    $null = Receive-Mcp $Ctx.Mcp $pending

    $under = [E2E]::At($cx, [int]($s.Height * 0.4))
    [E2E]::Click($cx, [int]($s.Height * 0.4))
    Start-Sleep -Milliseconds 300
    Write-Host "     clicked on $under; in front: $([E2E]::Foreground())"
    $n = Wait-Notch 'took control|tomaste el control|have control|Tienes el control'
    Check 'a click takes control: the notch says so' ($n -and $n.Text -match 'took control|tomaste el control|have control|Tienes el control') "text: $($n.Text)"
    Check-Drawn 'control notch' $n
    Check 'the agent is paused' ((Invoke-Tool $Ctx.Mcp 'list_machines') -match "$vm[^\n]*paused") ''
    Shot 'overlays-3-control'

    [E2E]::Combo([byte][char]'R')
    $n = Wait-Notch 'Recording|Grabando'
    Check 'Ctrl+Alt+Shift+R: the notch shows Recording' ($n -and $n.Text -match 'Recording|Grabando') "text: $($n.Text)"
    Check-Drawn 'recording notch' $n
    Shot 'overlays-4-recording'
    [E2E]::Combo([byte][char]'R')
    Start-Sleep -Seconds 2

    [E2E]::Combo([byte][char]'G')
    Start-Sleep -Seconds 2
    Shot 'overlays-5-panel'
    Check-NoFlash 'closing the side panel' { [E2E]::Combo([byte][char]'G') }

    [E2E]::Combo([byte][char]'A')
    $gone = Wait-For { $x = Get-Notch; -not ($x -and $x.Text -match 'took control|tomaste el control|have control|Tienes el control') } 8
    Check 'Ctrl+Alt+Shift+A gives the machine back' ([bool]$gone) "notch: $((Get-Notch).Text)"
    $answer = Invoke-Tool $Ctx.Mcp 'wait_for_person' @{ machine = $vm; waitSeconds = 10 }
    Check 'the agent has the machine again' ($answer -match "isn't paused|handed .* back") $answer
}
