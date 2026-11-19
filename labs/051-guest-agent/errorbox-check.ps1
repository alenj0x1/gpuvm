# The csrss error box case, closed: on a disposable from agent-tpl (installed build = agent 0.3.7), a hard-error box is
# raised by a detached process; screen.state's errorBoxRects says where it is relative to the agent's screen; a
# screenshot and a refused click. Then guest/agent/dist (0.3.8) is installed and the click's message and
# screen.refresh are checked. One lab lock; the disposable is deleted at the end.
param([string]$Template = 'agent-tpl', [string]$Name = 'agent051-box', [string]$Me = 'agent-guest')
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$outDir = Join-Path $PSScriptRoot ('out\errorbox-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $outDir | Out-Null
Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
function Step($m) { "[$(Get-Date -Format HH:mm:ss)] $m" | Out-Host }
function Call([string]$Method, [hashtable]$P = @{}, [int]$T = 30) { Invoke-GpuVMAgent -Name $Name -Method $Method -Params $P -TimeoutSec $T }
function Wait-Agent([string]$What, [string]$Version) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalMinutes -lt 10) {
        $r = try { Call 'agent.info' @{} 5 } catch { $null }
        if ($r -and $r.ok -and $r.result.signedIn -and (-not $Version -or $r.result.version -eq $Version)) { Step "$What after $([int]$sw.Elapsed.TotalSeconds) s"; return $r.result }
        Start-Sleep -Seconds 1
    }
    throw "timeout: $What"
}
function Box([string]$Label) {
    $home_ = (Call 'agent.info').result.home
    $w = Invoke-GpuVMAgent -Name $Name -Method files.write -Params @{ path = 'lab051-harness.exe' } -BlobPath (Join-Path $PSScriptRoot 'harness\target\release\harness.exe')
    Call 'exec.run' @{ file = 'cmd.exe'; args = @('/c', 'start', '', "$home_\lab051-harness.exe", 'guest-errorbox'); timeoutMs = 5000 } 20 | Out-Null
    Start-Sleep -Milliseconds 1500
    $st = (Call 'screen.state').result
    $shot = Call 'screen.capture' @{ format = 'png'; maxW = 3840; maxH = 2160 }
    if ($shot.ok) { Copy-Item $shot.blobPath (Join-Path $outDir "$Label.png") }
    $click = Call 'input.act' @{ actions = @(@{ type = 'click'; x = 300; y = 300 }) }
    [ordered]@{ upload = $w.ok; screen = $st.screen; errorBoxes = $st.errorBoxes; errorBoxRects = $st.errorBoxRects; foreground = $st.foreground; click = $click.error }
}

& (Join-Path $repo 'labs\042-admin-dock\take-lock.ps1') -What "lab 051: error box check on disposable $Name" -Me $Me -MaxMinutes 240
if ($LASTEXITCODE -ne 0) { throw 'no lock' }
$Results = [ordered]@{}
try {
    New-GpuVM -Name $Name -Template $Template -Disposable -Use agent -Override @{ vm = @{ memoryGB = 4; cpu = @{ count = 4 } } } -Confirm:$false | Out-Null
    $v = (Wait-Agent 'agent (installed build) ready').version
    $Results.installed = Box "box-$v"
    Step "$v : $($Results.installed | ConvertTo-Json -Compress -Depth 6)"

    # 0.3.8 from dist; the box from the first raiser is still up
    $gc = & (Get-Module GpuVM) { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $Name
    $staging = 'C:\ProgramData\GpuVM\Agent\staging'
    $s = New-PSSession -VMName $Name -Credential $gc
    Invoke-Command -Session $s { param($d) New-Item -ItemType Directory $d -Force | Out-Null } -ArgumentList $staging
    Get-ChildItem (Join-Path $repo 'guest\agent\dist') | ForEach-Object { Copy-Item $_.FullName -Destination $staging -ToSession $s -Force }
    $inst = Invoke-Command -Session $s -FilePath (Join-Path $repo 'guest\agent\install.ps1') -ArgumentList $staging
    Remove-PSSession $s
    $dist = Get-Content (Join-Path $repo 'guest\agent\dist\VERSION')
    Wait-Agent "agent $dist ready" $dist | Out-Null
    $st = (Call 'screen.state').result
    $click = Call 'input.act' @{ actions = @(@{ type = 'click'; x = 300; y = 300 }) }
    $refresh = @(); for ($i = 0; $i -lt 10; $i++) { $r = Call 'screen.refresh'; $refresh += $r.result.ms; $Results.refreshLast = $r }
    $Results.dist = [ordered]@{ version = $dist; errorBoxRects = $st.errorBoxRects; click = $click.error; refreshMs = $refresh }
    Step "$dist : $($Results.dist | ConvertTo-Json -Compress -Depth 6)"
}
catch { Step "FAILED: $($_.Exception.Message)"; throw }
finally {
    $Results | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $outDir 'results.json')
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 5
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Step "results: $outDir; VM left: $([bool](Get-VM -Name $Name -ErrorAction SilentlyContinue)); lock released"
}
