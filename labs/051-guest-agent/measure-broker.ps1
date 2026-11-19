# Lab 051, part 2: the measurements that need the screen, through GpuVM's real host side (the installed broker,
# Invoke-GpuVMAgent over its admin pipe) on a disposable VM from agent-tpl. One lab lock for the whole chain; the VM is
# turned off (and so deleted) at the end. Writes out\broker-<time>\results.json and sample images. Run elevated.
param([string]$Template = 'agent-tpl', [string]$Name = 'agent051-m', [string]$Me = 'agent-guest', [int]$N = 40, [switch]$Existing)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$outDir = Join-Path $PSScriptRoot ('out\broker-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $outDir | Out-Null
Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
$Results = [ordered]@{}
function Rec($k, $v) { $Results[$k] = $v; "$k : $($v | ConvertTo-Json -Compress -Depth 6)" | Out-Host }
function Stats([double[]]$v) {
    if (-not $v.Count) { return $null }
    $s = $v | Sort-Object
    [ordered]@{ n = $s.Count; p50 = [math]::Round($s[[int](($s.Count - 1) * 0.5)], 2); p95 = [math]::Round($s[[int](($s.Count - 1) * 0.95)], 2); min = [math]::Round($s[0], 2); max = [math]::Round($s[-1], 2) }
}
function Call([string]$Method, [hashtable]$P = @{}, [int]$Timeout = 30, [string]$Blob) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $a = @{ Name = $Name; Method = $Method; Params = $P; TimeoutSec = $Timeout }
    if ($Blob) { $a.BlobPath = $Blob }
    $r = Invoke-GpuVMAgent @a
    $r | Add-Member -NotePropertyName hostMs -NotePropertyValue $sw.Elapsed.TotalMilliseconds -Force
    $r
}
function Title { (Call 'screen.state').result.foreground.title }
function Wait-Title([scriptblock]$Ok, [int]$Sec = 15) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Sec) { $t = Title; if (& $Ok $t) { return $t }; Start-Sleep -Milliseconds 200 }
    $null
}
function Exec([string]$File, [string[]]$ArgList, [int]$Ms = 10000) { Call 'exec.run' @{ file = $File; args = $ArgList; timeoutMs = $Ms } ([math]::Ceiling($Ms / 1000) + 15) }
function Center($n) { @(($n.bbox[0] + $n.bbox[2] / 2), ($n.bbox[1] + $n.bbox[3] / 2)) }

& (Join-Path $repo 'labs\042-admin-dock\take-lock.ps1') -What "lab 051 part 2: measure through the broker on $Name (disposable from $Template)" -Me $Me
if ($LASTEXITCODE -ne 0) { throw 'no lock' }
try {
    # --- the machine ---------------------------------------------------------------------------------------------
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if ($Existing) {
        # an existing VM (agent051): started, then the broker installs the agent (new secret + agent password)
        if ((Get-VM -Name $Name).State -ne 'Running') { Start-VM -Name $Name }
        # wait for the signed-in desktop with the INSTALLED module only (wait-ready.ps1 imports the repo's copy too,
        # and two GpuVM modules break module-scoped calls)
        $gc = & (Get-Module GpuVM) { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $Name
        do {
            Start-Sleep -Seconds 2
            $u = try { Invoke-Command -VMName $Name -Credential $gc -ErrorAction Stop { (Get-CimInstance Win32_ComputerSystem).UserName } } catch { $null }
        } until ($u -or $sw.Elapsed.TotalMinutes -gt 10)
        "signed in: $u" | Out-Host
        $inst = Install-GpuVMAgent -Name $Name
        Rec 'install' $inst
    } else {
        # 4 GB / 4 threads like the other test VMs (the default profile asks 8 GB and doesn't fit next to others)
        New-GpuVM -Name $Name -Template $Template -Disposable -Use agent -Override @{ vm = @{ memoryGB = 4; cpu = @{ count = 4 } } } -Confirm:$false | Out-Null
    }
    $created = $sw.Elapsed.TotalSeconds
    do {
        Start-Sleep -Milliseconds 500
        $i = try { Invoke-GpuVMAgent -Name $Name -Method agent.info -TimeoutSec 5 -ErrorAction Stop } catch { $null }
    } until (($i -and $i.ok -and $i.result.signedIn) -or $sw.Elapsed.TotalMinutes -gt 10)
    $a = Get-GpuVMAgent -Name $Name -ErrorAction SilentlyContinue
    Rec 'machine' ([ordered]@{ createdS = [math]::Round($created, 1); agentReadyS = [math]::Round($sw.Elapsed.TotalSeconds, 1); agent = $a })
    Rec 'agent.info' (Call 'agent.info').result
    # Wait for the display to settle at its final mode
    Start-Sleep -Seconds 5

    # --- capture -------------------------------------------------------------------------------------------------
    $cells = [ordered]@{
        'webp-1280' = @{ format = 'webp' }; 'png-1280' = @{ format = 'png' }
        'webp-native' = @{ format = 'webp'; maxW = 3840; maxH = 2160 }; 'webp-region-400x300' = @{ format = 'webp'; region = @(200, 150, 400, 300) }
    }
    $cap = @{}; foreach ($k in $cells.Keys) { $cap[$k] = @{ host = @(); broker = @(); guest = @(); kb = @(); scale = @(); encode = @(); err = 0 } }
    for ($i = 0; $i -lt $N; $i++) {
        foreach ($k in $cells.Keys) {
            $r = Call 'screen.capture' $cells[$k]
            if (-not $r.ok) { $cap[$k].err++; $cap[$k].lastError = "$($r.error.code): $($r.error.message)"; continue }
            $c = $cap[$k]; $c.host += $r.hostMs; $c.broker += $r.ms; $c.guest += $r.result.ms.total; $c.kb += $r.blobBytes / 1KB
            $c.scale += $r.result.ms.scale; $c.encode += $r.result.ms.encode
            if ($i -eq 0) { Copy-Item $r.blobPath (Join-Path $outDir "capture-$k.$($r.blobFormat)"); $c.first = $r.result }
            Start-Sleep -Milliseconds (20 + (Get-Random -Maximum 60))
        }
    }
    $Results.capture = [ordered]@{}
    foreach ($k in $cells.Keys) { $c = $cap[$k]; $Results.capture[$k] = [ordered]@{ hostMs = Stats $c.host; brokerMs = Stats $c.broker; guestMs = Stats $c.guest; kb = Stats $c.kb; scaleMs = Stats $c.scale; encodeMs = Stats $c.encode; errors = $c.err; lastError = $c.lastError; first = $c.first } }
    Rec 'capture-summary' ($Results.capture.Keys | ForEach-Object { "$_ host p50 $($Results.capture[$_].hostMs.p50) guest p50 $($Results.capture[$_].guestMs.p50) kb $($Results.capture[$_].kb.p50) err $($Results.capture[$_].errors)" })

    # --- action -> screen (Notepad) ------------------------------------------------------------------------------
    Exec 'cmd.exe' @('/c', 'start', '', 'notepad.exe') | Out-Null
    $np = Wait-Title { param($t) $t -match 'Bloc de notas|Notepad' }
    $tree = (Call 'ui.tree').result
    $edit = $tree.nodes | Where-Object { $_.role -in 'edit', 'document' } | Select-Object -First 1
    if ($edit) {
        $c = Center $edit
        Call 'input.act' @{ actions = @(@{ type = 'click'; x = $c[0]; y = $c[1] }) } | Out-Null
        $region = @(($edit.bbox[0] + 2), ($edit.bbox[1] + 2), 320, 60)
        $lat = @(); $polls = @(); $timeouts = 0; $refused = $null
        for ($i = 0; $i -lt $N; $i++) {
            Start-Sleep -Milliseconds (150 + (Get-Random -Maximum 250))
            $before = (Get-FileHash (Call 'screen.capture' @{ format = 'png'; region = $region }).blobPath).Hash
            $act = if ($i % 2 -eq 0) { @{ type = 'type'; text = 'm' } } else { @{ type = 'key'; keys = 'backspace' } }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Call 'input.act' @{ actions = @($act) }
            if (-not $r.ok) { $refused = $r.error; break }
            $k = 0; $got = $null
            while ($sw.Elapsed.TotalMilliseconds -lt 1500) {
                $k++
                if ((Get-FileHash (Call 'screen.capture' @{ format = 'png'; region = $region }).blobPath).Hash -ne $before) { $got = $sw.Elapsed.TotalMilliseconds; break }
            }
            if ($got) { $lat += $got; $polls += $k } else { $timeouts++ }
        }
        Rec 'latency' ([ordered]@{ window = $np; region = $region; actionToScreenMs = Stats $lat; capturesPerSample = Stats $polls; timeouts = $timeouts; refused = $refused })
    } else { Rec 'latency' @{ error = 'no edit box'; window = $np } }
    Exec 'taskkill.exe' @('/im', 'notepad.exe', '/f') | Out-Null

    # --- Edge: input and ui.invoke, read back through the page title --------------------------------------------
    $page = Join-Path $PSScriptRoot 'page.html'
    $w = Call 'files.write' @{ path = 'Desktop\Received\lab051.html'; mkdirs = $true } -Blob $page
    Exec 'cmd.exe' @('/c', 'start', '', 'msedge', '--no-first-run', 'file:///C:/Users/agent/Desktop/Received/lab051.html') | Out-Null
    $t0 = Wait-Title { param($t) $t -like '*n=0;*' } 40
    $shot = Call 'screen.capture' @{}
    if ($shot.ok) { Copy-Item $shot.blobPath (Join-Path $outDir "edge.$($shot.blobFormat)") }
    $edge = [ordered]@{ write = $w.ok; title = $t0; nowTitle = Title }
    if ($t0) {
        $first = Call 'ui.tree'
        $edge.firstTree = [ordered]@{ ms = $first.result.ms; nodes = $first.result.nodes.Count; queries = $first.result.queries }
        $warm = @(); for ($i = 0; $i -lt 5; $i++) { $warm += (Call 'ui.tree').result.ms }; $edge.warmTreeMs = Stats $warm
        $tree = (Call 'ui.tree').result
        $f = $tree.nodes | Where-Object { $_.role -eq 'edit' -and $_.name -notmatch 'direcci|address|Buscar' } | Select-Object -First 1
        $b = $tree.nodes | Where-Object { $_.role -eq 'button' -and $_.name -eq 'Press' } | Select-Object -First 1
        if ($f -and $b) {
            $fc = Center $f; $bc = Center $b
            $edge.clickType = [bool](Call 'input.act' @{ actions = @(@{ type = 'click'; x = $fc[0]; y = $fc[1] }, @{ type = 'type'; text = 'hola GpuVM ñ' }) }).ok -and [bool](Wait-Title { param($t) $t -like '*v=hola GpuVM ñ;*' } 3)
            $edge.keyRepeat = [bool](Call 'input.act' @{ actions = @(@{ type = 'key'; keys = 'backspace'; repeat = 6 }) }).ok -and [bool](Wait-Title { param($t) $t -like '*v=hola G;*' } 3)
            $edge.uiInvoke = [bool](Call 'ui.invoke' @{ id = $b.id; action = 'invoke' }).ok -and [bool](Wait-Title { param($t) $t -like '*n=1;*' } 3)
            $edge.clickButton = [bool](Call 'input.act' @{ actions = @(@{ type = 'click'; x = $bc[0]; y = $bc[1] }) }).ok -and [bool](Wait-Title { param($t) $t -like '*n=2;*' } 3)
            $sv = Call 'ui.invoke' @{ id = $f.id; action = 'setValue'; value = 'uia' }
            $edge.setValue = [ordered]@{ ok = $sv.ok; error = $sv.error; title = (Wait-Title { param($t) $t -like '*v=uia;*' } 3) }
            $edge.scroll = [bool](Call 'input.act' @{ actions = @(@{ type = 'scroll'; x = $fc[0]; y = ($fc[1] + 300); dy = 5 }) }).ok -and [bool](Wait-Title { param($t) $t -match 'y=[1-9]' } 3)
        } else { $edge.nodes = $tree.nodes | Select-Object -First 30 role, name }
    }
    Rec 'edge' $edge
    Exec 'taskkill.exe' @('/im', 'msedge.exe', '/f') | Out-Null

    # --- secure desktop: a UAC prompt raised by the agent user ----------------------------------------------------
    $mod = Get-Module GpuVM
    $guest = & $mod { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $Name
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Exec 'powershell.exe' @('-NoProfile', '-Command', 'Start-Process cmd.exe -Verb RunAs') 2500 | Out-Null
    $onMs = $null; while ($sw.Elapsed.TotalSeconds -lt 10) { if ((Call 'screen.state').result.desktop -ne 'default') { $onMs = $sw.Elapsed.TotalMilliseconds; break }; Start-Sleep -Milliseconds 100 }
    $probe = [ordered]@{
        capture = (Call 'screen.capture' @{}).error.code
        click = (Call 'input.act' @{ actions = @(@{ type = 'click'; x = 100; y = 100 }) }).error.code
        type = (Call 'input.act' @{ actions = @(@{ type = 'type'; text = 'x' }) }).error.code
        tree = (Call 'ui.tree').error.code
    }
    $offMs = $null
    if ($guest) {
        Invoke-Command -VMName $Name -Credential $guest { Stop-Process -Name consent -Force -ErrorAction SilentlyContinue }
        $sw.Restart(); while ($sw.Elapsed.TotalSeconds -lt 30) { if ((Call 'screen.state').result.desktop -eq 'default') { $offMs = $sw.Elapsed.TotalMilliseconds; break }; Start-Sleep -Milliseconds 100 }
    }
    Rec 'secure-desktop' ([ordered]@{ onMs = $onMs; refused = $probe; closedFromOutside = [bool]$guest; offMs = $offMs; captureAfter = (Call 'screen.capture' @{}).ok })

    # --- a csrss error box raised by the agent user ---------------------------------------------------------------
    $h = Join-Path $PSScriptRoot 'harness\target\release\harness.exe'
    $hw = Call 'files.write' @{ path = 'lab051-harness.exe' } -Blob $h
    Exec "$((Call 'agent.info').result.home)\lab051-harness.exe" @('guest-errorbox') 3000 | Out-Null
    Start-Sleep -Milliseconds 800
    $st = (Call 'screen.state').result
    $shot = Call 'screen.capture' @{}
    if ($shot.ok) { Copy-Item $shot.blobPath (Join-Path $outDir "errorbox.$($shot.blobFormat)") }
    $click = Call 'input.act' @{ actions = @(@{ type = 'click'; x = 500; y = 400 }) }
    Rec 'error-box' ([ordered]@{ upload = $hw.ok; state = $st; captureOk = $shot.ok; click = $click.error })
}
finally {
    $Results | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $outDir 'results.json')
    if ($Existing) { Stop-VM -Name $Name -ErrorAction SilentlyContinue }   # clean shutdown, the VM stays
    elseif (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue }
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    "results: $outDir; lock released $(Get-Date -Format HH:mm:ss)"
}
