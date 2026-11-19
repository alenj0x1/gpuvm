# Lab 049: input and UI Automation from the session helper, as the signed-in user (gpuvm, medium token from
# WTSQueryUserToken) and as a separate standard user `agent` started on the same desktop (CreateProcessWithLogonW from
# the user's session, like runas). Checks that clicks, text, keys, scroll and a button click really land (read back
# with UIA), measures action -> screen latency, proves an elevated foreground window is reported as blocked_elevated
# instead of failing silently, and times the UIA tree of Explorer, Notepad, Settings and Edge.
# Test VM only (creates the local user `agent`, removed at the end). Run elevated:
#   pwsh -File labs/049-input-uia/run.ps1 -Name agentlab
param(
    [Parameter(Mandatory)][string]$Name,
    [int]$Rounds = 2,
    [int]$LatencyN = 40,
    [int]$UiaReps = 6,
    [string]$OutDir = (Join-Path $PSScriptRoot "out\run-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
)
$ErrorActionPreference = 'Stop'
if ($Name -eq 'win-gpu') { throw 'Test VM only.' }
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
. (Join-Path $root 'tools\latency\common.ps1')
. (Join-Path $root 'labs\048-capture\guest.ps1')
New-Item -ItemType Directory -Force $OutDir | Out-Null
$labVm = Get-LatencyVM -Name $Name
$sess = New-PSSession -VMName $Name -Credential $labVm.Guest
$log = Join-Path $OutDir 'steps.jsonl'
function Step([string]$who, [string]$what, $res) {
    $line = [ordered]@{ t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); who = $who; what = $what; result = $res }
    Add-Content $log ($line | ConvertTo-Json -Compress -Depth 6)
}
$pwFile = 'C:\GpuVMLab048\agent-pw.txt'
$agentPw = $null

# Runs the probe as `who`: gpuvm (launch) or agent (launch -> launch-as). Returns the parsed JSON (or $null).
function Probe([string]$who, [string[]]$probeArgs, [int]$timeout = 120) {
    $pa = if ($who -eq 'agent') {
        Invoke-Command -Session $sess -ArgumentList $pwFile, $agentPw {
            param($f, $p)
            Set-Content $f $p -NoNewline
            icacls $f /inheritance:r /grant:r 'SYSTEM:R' 'Administrators:F' "$env:COMPUTERNAME\gpuvm:R" | Out-Null
        }
        @('launch-as', '--user', 'agent', '--password-file', $pwFile, '--wait', '--') + $probeArgs
    } else { $probeArgs }
    try { $r = Invoke-GuestProbe -Session $sess -ProbeArgs $pa -TimeoutSec $timeout }
    finally { if ($who -eq 'agent') { Invoke-Command -Session $sess -ArgumentList $pwFile { param($f) Remove-Item $f -Force -ErrorAction SilentlyContinue } } }
    if (-not $r.result) { Write-Warning "no result ($who $($probeArgs -join ' ')): launch=$($r.launch)"; return $null }
    try { $r.result | ConvertFrom-Json } catch { Write-Warning "bad json: $($r.result)"; $null }
}

function Center($bbox, $screen) {
    # bbox [x, y, w, h] in physical pixels; screen [left, top, right, bottom] of the virtual desktop
    $vw = $screen[2] - $screen[0]; $vh = $screen[3] - $screen[1]
    @{ x = [math]::Round(($bbox[0] + $bbox[2] / 2 - $screen[0]) / $vw, 5); y = [math]::Round(($bbox[1] + $bbox[3] / 2 - $screen[1]) / $vh, 5) }
}

function Close-GuestApps([string[]]$names) {
    Invoke-Command -Session $sess -ArgumentList (, $names) { param($n) Get-Process $n -ErrorAction SilentlyContinue | Stop-Process -Force }
    Start-Sleep -Milliseconds 500
}

$summary = [System.Collections.Generic.List[object]]::new()
try {
    Install-GuestProbe -Session $sess
    $screen = ((Invoke-GuestProbe -Session $sess -ProbeArgs 'outputs').result | ConvertFrom-Json | Where-Object attached | Select-Object -First 1).rect
    "virtual desktop: $($screen -join ',')"

    # The standard user `agent` (Users only), random password known only to this run.
    $bytes = [byte[]]::new(18); [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $agentPw = 'Ag9!' + [Convert]::ToBase64String($bytes).Replace('/', 'x').Replace('+', 'y')
    Invoke-Command -Session $sess -ArgumentList $agentPw {
        param($p)
        if (-not (Get-LocalUser agent -ErrorAction SilentlyContinue)) {
            New-LocalUser -Name agent -Password (ConvertTo-SecureString $p -AsPlainText -Force) -AccountNeverExpires -PasswordNeverExpires -Description 'GpuVM lab 049' | Out-Null
        } else { Set-LocalUser -Name agent -Password (ConvertTo-SecureString $p -AsPlainText -Force) }
        Add-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-545').Name -Member agent -ErrorAction SilentlyContinue
        # The probe folder must be reachable by agent
        icacls C:\GpuVMLab048 /grant '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    }
    foreach ($who in 'gpuvm', 'agent') {
        $w = Probe $who @('whoami')
        Step $who 'whoami' $w
        "$who -> $($w | ConvertTo-Json -Compress)"
    }

    for ($round = 1; $round -le $Rounds; $round++) {
        foreach ($who in 'gpuvm', 'agent') {
            $row = [ordered]@{ round = $round; who = $who }
            Close-GuestApps 'notepad'
            Start-GuestApp -Session $sess -Exe 'C:\Windows\System32\notepad.exe' | Out-Null
            Start-Sleep -Seconds 1
            $f = Probe $who @('focus', '--title', 'Bloc de notas'); Step $who 'focus' $f
            $row.focus = $f.ok
            $tree = Probe $who @('uia', '--max-lines', '200'); Step $who 'uia-notepad' $tree
            $edit = $tree.elements | Where-Object role -in 'edit', 'document' | Select-Object -First 1
            if (-not $edit) { Write-Warning "$who no edit element"; $summary.Add([pscustomobject]$row); continue }
            $c = Center $edit.bbox $screen
            $a = Probe $who @('act', '--do', 'click', '--x', "$($c.x)", '--y', "$($c.y)"); Step $who 'click-edit' $a
            $text = "hola agente $who $round"
            $a = Probe $who @('act', '--do', 'type', '--text', $text); Step $who 'type' $a
            $row.typeResult = $a.result
            Start-Sleep -Milliseconds 300
            $fo = Probe $who @('focused'); Step $who 'focused-after-type' $fo
            $row.textLanded = ($fo.value -like "*$text*")
            $a = Probe $who @('act', '--do', 'key', '--combo', 'ctrl+a'); Step $who 'ctrl+a' $a
            $a = Probe $who @('act', '--do', 'key', '--combo', 'backspace'); Step $who 'backspace' $a
            $fo = Probe $who @('focused'); Step $who 'focused-after-clear' $fo
            $row.keysLanded = ([string]::IsNullOrWhiteSpace($fo.value))
            # scroll: 120 lines, back to top, wheel down over the text
            $lines = (1..120 | ForEach-Object { "linea $_" }) -join "`n"
            $null = Probe $who @('act', '--do', 'type', '--text', $lines)
            $null = Probe $who @('act', '--do', 'key', '--combo', 'ctrl+home')
            $before = Probe $who @('focused')
            $a = Probe $who @('act', '--do', 'scroll', '--x', "$($c.x)", '--y', "$($c.y)", '--delta', '-1200'); Step $who 'scroll' $a
            Start-Sleep -Milliseconds 300
            $after = Probe $who @('focused'); Step $who 'focused-after-scroll' $after
            $row.scrollBefore = $before.verticalScrollPercent; $row.scrollAfter = $after.verticalScrollPercent
            $row.scrollLanded = ($after.verticalScrollPercent -gt $before.verticalScrollPercent)
            # button: Find dialog, click its Cancel button by its UIA box
            $null = Probe $who @('act', '--do', 'key', '--combo', 'ctrl+f')
            Start-Sleep -Milliseconds 600
            $dlg = Probe $who @('uia', '--max-lines', '100'); Step $who 'uia-find-dialog' $dlg
            $btn = $dlg.elements | Where-Object { $_.role -eq 'button' -and $_.name -match 'Cancelar|Cancel' } | Select-Object -First 1
            if ($btn) {
                $bc = Center $btn.bbox $screen
                $a = Probe $who @('act', '--do', 'click', '--x', "$($bc.x)", '--y', "$($bc.y)"); Step $who 'click-cancel' $a
                Start-Sleep -Milliseconds 500
                $fg = Probe $who @('fg'); Step $who 'fg-after-cancel' $fg
                $row.dialogWindow = $dlg.window
                $row.buttonLanded = ($fg.title -like '*Bloc de notas*')
            } else { $row.buttonLanded = $false; $row.dialogWindow = $dlg.window }
            # action -> screen latency (typing in Notepad)
            $null = Probe $who @('act', '--do', 'key', '--combo', 'ctrl+end')
            $lat = Probe $who @('latency', '--n', "$LatencyN") 300; Step $who 'latency' $lat
            $row.latP50 = $lat.p50; $row.latP95 = $lat.p95; $row.latN = $lat.n; $row.latTimeouts = $lat.timeouts; $row.latSkipped = $lat.skipped
            $summary.Add([pscustomobject]$row)
            [pscustomobject]$row | Format-List | Out-String
        }
    }

    # Elevated foreground: Notepad started elevated by a highest-run-level task of the user (no prompt).
    Close-GuestApps 'notepad'
    Invoke-Command -Session $sess {
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        $a = New-ScheduledTaskAction -Execute 'C:\Windows\System32\notepad.exe'
        Register-ScheduledTask -TaskName GpuVMLab049-elevated -Action $a -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest) -Force | Out-Null
        Start-ScheduledTask GpuVMLab049-elevated
        Start-Sleep -Seconds 2
        Unregister-ScheduledTask GpuVMLab049-elevated -Confirm:$false
    }
    foreach ($who in 'gpuvm', 'agent') {
        $f = Probe $who @('focus', '--title', 'Bloc de notas'); Step $who 'elev-focus' $f
        $fg = Probe $who @('fg'); Step $who 'elev-fg' $fg
        $checked = Probe $who @('act', '--do', 'type', '--text', 'no deberia llegar'); Step $who 'elev-type-checked' $checked
        $forced = Probe $who @('act', '--do', 'type', '--text', 'x', '--force'); Step $who 'elev-type-forced' $forced
        Start-Sleep -Milliseconds 300
        $fg2 = Probe $who @('fg'); Step $who 'elev-fg-after' $fg2
        $tree = Probe $who @('uia', '--max-lines', '20'); Step $who 'elev-uia' $tree
        $e = [pscustomobject]@{
            who = $who; focusOk = $f.ok; verdict = $fg.verdict; targetIntegrity = $fg.targetIntegrity; openErr = $fg.openErr
            checkedResult = $checked.result; checkedInjected = $checked.injected
            forcedSent = $forced.sent; forcedOf = $forced.of; forcedLastError = $forced.lastError
            titleBefore = $fg.title; titleAfterForced = $fg2.title; uiaOk = $tree.ok; uiaTotal = $tree.total; uiaError = $tree.error
        }
        $e | Format-List | Out-String
        $summary.Add($e)
    }
    Close-GuestApps 'notepad'

    # UIA timing per app (as gpuvm; agent once on Notepad and Edge to compare)
    Invoke-Command -Session $sess {
        Get-ChildItem C:\Windows\System32 -Filter *.dll | Select-Object -First 120 Name, Length | Format-Table | Out-String | Set-Content C:\GpuVMLab048\scene.txt
        $html = '<!doctype html><title>GpuVM lab 049</title><h1>Formulario</h1>' + ((1..20 | ForEach-Object { "<p><label>Campo $_ <input id=f$_></label> <button>Enviar $_</button> <a href=#$_>Enlace $_</a></p>" }) -join '')
        Set-Content C:\GpuVMLab048\page.html $html -Encoding UTF8
    }
    $apps = @(
        @{ key = 'explorer'; exe = 'C:\Windows\explorer.exe'; args = @('C:\Windows'); title = 'Windows' },
        @{ key = 'notepad'; exe = 'C:\Windows\System32\notepad.exe'; args = @('C:\GpuVMLab048\scene.txt'); title = 'scene' },
        @{ key = 'settings'; exe = 'C:\Windows\explorer.exe'; args = @('ms-settings:display'); title = 'Configuraci' },
        @{ key = 'edge'; exe = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'; args = @('--no-first-run', '--no-default-browser-check', 'file:///C:/GpuVMLab048/page.html'); title = 'GpuVM lab 049' }
    )
    foreach ($app in $apps) {
        Start-GuestApp -Session $sess -Exe $app.exe -AppArgs $app.args | Out-Null
        Start-Sleep -Seconds 5
        foreach ($who in @('gpuvm') + $(if ($app.key -in 'notepad', 'edge') { 'agent' })) {
            $f = Probe $who @('focus', '--title', $app.title)
            if (-not $f.ok) { Write-Warning "$($app.key): focus failed for $who ($($f | ConvertTo-Json -Compress))" }
            $times = @()
            for ($i = 1; $i -le $UiaReps; $i++) {
                $t = Probe $who @('uia', '--max-lines', '400'); Step $who "uia-$($app.key)-$i" $t
                $times += [pscustomobject]@{ i = $i; fetchMs = $t.fetchMs; createMs = $t.createMs; total = $t.total; visible = $t.visible; interactive = $t.interactiveVisible; window = $t.window }
            }
            $raw = Probe $who @('uia', '--raw', '--max-lines', '0'); Step $who "uia-$($app.key)-raw" $raw
            $warm = $times | Select-Object -Skip 1
            $u = [pscustomobject]@{
                app = $app.key; who = $who; window = $times[0].window
                firstFetchMs = $times[0].fetchMs; firstTotal = $times[0].total
                warmFetchMsMedian = ($warm.fetchMs | Sort-Object)[[int]($warm.Count / 2)]
                warmFetchMsMax = ($warm.fetchMs | Measure-Object -Maximum).Maximum
                total = $times[-1].total; visible = $times[-1].visible; interactiveVisible = $times[-1].interactive
                rawTotal = $raw.total; rawFetchMs = $raw.fetchMs
            }
            $u | Format-List | Out-String
            $summary.Add($u)
        }
    }
    # one screenshot of the Edge page as the model would get it
    $shot = Invoke-GuestProbe -Session $sess -ProbeArgs 'capture', '--method', 'dxgi', '--n', '1', '--save', 'C:\GpuVMLab048\out'
    Copy-Item -FromSession $sess 'C:\GpuVMLab048\out\dxgi-small.png' -Destination (Join-Path $OutDir 'edge-1280.png') -ErrorAction SilentlyContinue
}
finally {
    $summary | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutDir 'summary.json')
    try {
        Close-GuestApps 'notepad', 'msedge', 'SystemSettings'
        Invoke-Command -Session $sess {
            Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { $_.CommandLine -match 'C:\\Windows$|C:\\Windows"' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Get-CimInstance Win32_Process | Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue).User -eq 'agent' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 1
            Remove-LocalUser agent -ErrorAction SilentlyContinue
            Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -like '*\agent' } | Remove-CimInstance -ErrorAction SilentlyContinue
        }
        Remove-GuestProbe -Session $sess
    } catch { Write-Warning "cleanup: $_" }
    Remove-PSSession $sess -ErrorAction SilentlyContinue
    "out: $OutDir"
}
