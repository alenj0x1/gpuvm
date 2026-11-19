# Agent-mode displays, before/after, with NO viewer connected: does a window the agent opens land where its screenshot
# sees it? A disposable from agent-tpl with the installed build (agent 0.3.2 via the broker) is the baseline; then the
# guest/agent/dist build (0.3.3: the virtual display made the only, primary display) is installed with install.ps1
# and the same check runs again. Saves both screenshots. One lab lock; the disposable is deleted at the end.
param([string]$Template = 'agent-tpl', [string]$Name = 'agent051-disp', [string]$Me = 'agent-guest')
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$outDir = Join-Path $PSScriptRoot ('out\display-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $outDir | Out-Null
Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
function Step($m) { "[$(Get-Date -Format HH:mm:ss)] $m" | Out-Host }
function Call([string]$Method, [hashtable]$P = @{}, [int]$T = 30) { Invoke-GpuVMAgent -Name $Name -Method $Method -Params $P -TimeoutSec $T }
function Wait-Agent([string]$What) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalMinutes -lt 10) {
        $r = try { Call 'agent.info' @{} 5 } catch { $null }
        if ($r -and $r.ok -and $r.result.signedIn) { Step "$What after $([int]$sw.Elapsed.TotalSeconds) s"; return $r.result }
        Start-Sleep -Seconds 2
    }
    throw "timeout: $What"
}
# Opens Notepad as the agent and reports where it is relative to the agent's screen, plus a screenshot.
function Check([string]$Label) {
    Call 'exec.run' @{ file = 'cmd.exe'; args = @('/c', 'taskkill', '/im', 'notepad.exe', '/f'); timeoutMs = 5000 } 20 | Out-Null
    Call 'exec.run' @{ file = 'cmd.exe'; args = @('/c', 'start', '', 'notepad.exe'); timeoutMs = 5000 } 20 | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew(); $title = $null
    while ($sw.Elapsed.TotalSeconds -lt 15) { $t = (Call 'screen.state').result.foreground.title; if ($t -match 'Bloc de notas|Notepad') { $title = $t; break }; Start-Sleep -Milliseconds 300 }
    $info = (Call 'agent.info').result
    $tree = Call 'ui.tree' @{ interactiveOnly = $false; maxNodes = 5 }
    $win = $tree.result.nodes | Select-Object -First 1
    $shot = Call 'screen.capture' @{ format = 'png'; maxW = 3840; maxH = 2160 }
    if ($shot.ok) { Copy-Item $shot.blobPath (Join-Path $outDir "$Label.png") }
    $b = $win.bbox
    $inside = $b -and $b[0] -ge 0 -and $b[1] -ge 0 -and ($b[0] + $b[2]) -le $shot.result.screen.w -and ($b[1] + $b[3]) -le $shot.result.screen.h
    [ordered]@{
        version = $info.version; displays = $info.displays; screen = $info.screen
        foreground = $title; notepadBbox = $b; screenshot = "$($shot.result.screen.w)x$($shot.result.screen.h)"
        notepadInsideScreenshot = [bool]$inside
    }
}

& (Join-Path $repo 'labs\042-admin-dock\take-lock.ps1') -What "lab 051: display test on disposable $Name" -Me $Me -MaxMinutes 120
if ($LASTEXITCODE -ne 0) { throw 'no lock' }
$R = [ordered]@{}
try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    New-GpuVM -Name $Name -Template $Template -Disposable -Use agent -Override @{ vm = @{ memoryGB = 4; cpu = @{ count = 4 } } } -Confirm:$false | Out-Null
    Step "created in $([int]$sw.Elapsed.TotalSeconds) s"
    Wait-Agent 'agent (installed build) connected' | Out-Null
    Start-Sleep -Seconds 5
    $R.before = Check 'before'
    Step "before: $($R.before | ConvertTo-Json -Compress -Depth 5)"

    # 0.3.3 from guest/agent/dist, the broker's install contract (secret stays: install.ps1 keeps it)
    $gc = & (Get-Module GpuVM) { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $Name
    $staging = 'C:\ProgramData\GpuVM\Agent\staging'
    $s = New-PSSession -VMName $Name -Credential $gc
    Invoke-Command -Session $s { param($d) New-Item -ItemType Directory $d -Force | Out-Null } -ArgumentList $staging
    Get-ChildItem (Join-Path $repo 'guest\agent\dist') | ForEach-Object { Copy-Item $_.FullName -Destination $staging -ToSession $s -Force }
    $inst = Invoke-Command -Session $s -FilePath (Join-Path $repo 'guest\agent\install.ps1') -ArgumentList $staging
    Step "install.ps1: version $($inst.version) fastPath $($inst.fastPath)"
    $sw.Restart()
    Wait-Agent 'agent 0.3.3 connected' | Out-Null
    Start-Sleep -Seconds 3
    $R.helperLog = Invoke-Command -Session $s { Get-Content C:\ProgramData\GpuVM\Agent\logs\agent.log -Tail 6 -Encoding UTF8 }
    Remove-PSSession $s
    $R.after = Check 'after'
    Step "after: $($R.after | ConvertTo-Json -Compress -Depth 5)"
    $R.helperLog | ForEach-Object { Step "guest log: $_" }
}
catch { Step "FAILED: $($_.Exception.Message)"; throw }
finally {
    $R | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $outDir 'results.json')
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 5
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Step "results: $outDir; VM left: $([bool](Get-VM -Name $Name -ErrorAction SilentlyContinue)); lock released"
}
