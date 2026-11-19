# Does screen.refresh give a duplication-based capture (Sunshine's ddx) a new frame of a still desktop? On a disposable
# from agent-tpl (installed build, agent 0.4.1), the harness opens DXGI Desktop Duplication on the agent's display as
# the agent user and, in interleaved rounds, waits until no frame came for 1.5 s, then does nothing (A) or repaints the
# desktop exactly like screen.refresh (B), and records whether a presented frame arrives within 1 s. One lab lock;
# the disposable is deleted at the end. (The full viewer path needs an MCP session: --view only opens a taken machine.)
param([string]$Template = 'agent-tpl', [string]$Name = 'agent051-dup', [string]$Me = 'agent-guest', [int]$Rounds = 40)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$outDir = Join-Path $PSScriptRoot ('out\dup-refresh-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $outDir | Out-Null
Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
function Step($m) { "[$(Get-Date -Format HH:mm:ss)] $m" | Out-Host }
& (Join-Path $repo 'labs\042-admin-dock\take-lock.ps1') -What "lab 051: ddx frame on screen.refresh, disposable $Name" -Me $Me -MaxMinutes 240
if ($LASTEXITCODE -ne 0) { throw 'no lock' }
try {
    New-GpuVM -Name $Name -Template $Template -Disposable -Use agent -Override @{ vm = @{ memoryGB = 4; cpu = @{ count = 4 } } } -Confirm:$false | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do { Start-Sleep -Seconds 1; $r = try { Invoke-GpuVMAgent -Name $Name -Method agent.info -TimeoutSec 5 } catch { $null } } until (($r -and $r.ok -and $r.result.signedIn) -or $sw.Elapsed.TotalMinutes -gt 8)
    Step "agent $($r.result.version) ready, screen $($r.result.screen | ConvertTo-Json -Compress)"
    # the agent arranges the displays a few seconds after sign-in (0.4.1): duplication must open after that
    $sw.Restart()
    do { Start-Sleep -Seconds 1; $r = Invoke-GpuVMAgent -Name $Name -Method agent.info -TimeoutSec 5 } until ((@($r.result.displays).Count -eq 1 -and $r.result.screen.w -ge 1280) -or $sw.Elapsed.TotalSeconds -gt 60)
    Start-Sleep -Seconds 3
    Step "displays: $($r.result.displays.Count), screen $($r.result.screen | ConvertTo-Json -Compress)"
    $ref = Invoke-GpuVMAgent -Name $Name -Method screen.refresh -TimeoutSec 10
    Step "screen.refresh through the broker: ok=$($ref.ok) $($ref.result | ConvertTo-Json -Compress) $($ref.error | ConvertTo-Json -Compress)"
    $gc = & (Get-Module GpuVM) { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $Name
    $s = New-PSSession -VMName $Name -Credential $gc
    Copy-Item (Join-Path $PSScriptRoot 'harness\target\release\harness.exe') -Destination 'C:\Users\Public\lab051-harness.exe' -ToSession $s -Force
    $rows = Invoke-Command -Session $s {
        param($n)
        Remove-Item C:\Users\Public\lab051-dup.json -ErrorAction SilentlyContinue
        $a = New-ScheduledTaskAction -Execute 'C:\Users\Public\lab051-harness.exe' -Argument "guest-dup-refresh $n"
        $p = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\agent" -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName Lab051Dup -Action $a -Principal $p -Force | Out-Null
        Start-ScheduledTask -TaskName Lab051Dup
        $t = 0; do { Start-Sleep -Seconds 1; $t++ } while (-not (Test-Path C:\Users\Public\lab051-dup.json) -and $t -lt 900)
        Unregister-ScheduledTask -TaskName Lab051Dup -Confirm:$false
        Get-Content C:\Users\Public\lab051-dup.json -Raw
    } -ArgumentList $Rounds
    Remove-PSSession $s
    Set-Content (Join-Path $outDir 'rounds.json') $rows
    $data = $rows | ConvertFrom-Json
    if ($data.error) { throw "probe: $($data.error)" }
    foreach ($v in 'none', 'refresh') {
        $set = @($data | Where-Object { $_.variant -eq $v -and $_.still })
        $hit = @($set | Where-Object { $null -ne $_.frameMs })
        $ms = @($hit | ForEach-Object { [double]$_.frameMs } | Sort-Object)
        $p50 = if ($ms.Count) { $ms[[int](($ms.Count - 1) * 0.5)] } else { $null }
        $p95 = if ($ms.Count) { $ms[[int](($ms.Count - 1) * 0.95)] } else { $null }
        Step "$v : a new frame within 1 s in $($hit.Count) of $($set.Count) still rounds; ms p50 $p50 p95 $p95 (not still: $(@($data | Where-Object { $_.variant -eq $v -and -not $_.still }).Count))"
    }
}
catch { Step "FAILED: $($_.Exception.Message)"; throw }
finally {
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 5
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Step "results: $outDir; VM left: $([bool](Get-VM -Name $Name -ErrorAction SilentlyContinue)); lock released"
}
