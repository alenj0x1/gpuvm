# Fix candidate for the no-display copies (readd-test: a cold stop + start of the VM brought the display back on 2 of 2
# bad copies; restarts from inside Windows and Restart-VM never did). The claim path plus one cold cycle after the
# agent's install: copy, start, Install-GpuVMAgent (its restart), wait until the agent answers, Stop-VM (Windows shuts
# down) + Start-VM, then the agent must report its display within 60 s. Counts copies with no display; also records
# whether each copy had a display BEFORE the cold cycle (the failure rate without the fix, same run). One lab lock.
param([string]$Template = 'agent-tpl', [int]$Copies = 12, [string]$Me = 'agent-guest')
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$outFile = Join-Path $PSScriptRoot ('out\coldcycle-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
$m = Get-Module GpuVM
function Step($t) { "[$(Get-Date -Format HH:mm:ss)] $t" | Out-Host }
function Info([string]$n) { try { (Invoke-GpuVMAgent -Name $n -Method agent.info -TimeoutSec 5).result } catch { $null } }
function HasDisplay($x) { $x -and $null -ne $x.displays -and @($x.displays | Where-Object { $_.adapter }).Count -ge 1 }
function WaitDisplay([string]$n, [int]$sec) {
    $w = [Diagnostics.Stopwatch]::StartNew(); $x = $null
    do { Start-Sleep -Seconds 2; $x = Info $n } until ((HasDisplay $x) -or $w.Elapsed.TotalSeconds -gt $sec)
    [pscustomobject]@{ ok = [bool](HasDisplay $x); s = [math]::Round($w.Elapsed.TotalSeconds); text = if (HasDisplay $x) { @($x.displays | ForEach-Object { "$($_.adapter) $($_.rect -join ',')" }) -join ' | ' } else { '' } }
}
& (Join-Path $repo 'labs\042-admin-dock\take-lock.ps1') -What "lab 051: cold cycle after install, $Copies copies of $Template" -Me $Me -MaxMinutes 240
if ($LASTEXITCODE -ne 0) { throw 'no lock' }
$rows = [System.Collections.Generic.List[object]]::new()
try {
    for ($c = 1; $c -le $Copies; $c++) {
        $name = "a051k$c"
        $row = [ordered]@{ copy = $c }
        try {
            New-GpuVM -Name $name -Template $Template | Out-Null
            Set-VMMemory -VMName $name -DynamicMemoryEnabled $false -StartupBytes 3GB
            Start-VM -Name $name
            $gc = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $name
            & $m { param($n, $cr) Wait-GuestReady -Name $n -Credential $cr } $name $gc
            Install-GpuVMAgent -Name $name | Out-Null
            $before = WaitDisplay $name 60
            $row.beforeCycle = $before.ok
            $sw = [Diagnostics.Stopwatch]::StartNew()
            Stop-VM -Name $name -Force
            $row.stopS = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            Start-VM -Name $name
            $after = WaitDisplay $name 90
            $row.afterCycle = $after.ok; $row.afterS = $after.s; $row.display = $after.text
            $row.cycleS = [math]::Round($sw.Elapsed.TotalSeconds)
            Step "[$c] before the cold cycle: $(if ($before.ok) { 'display' } else { 'NO display' }); after: $(if ($after.ok) { "$($after.text) in $($after.s) s" } else { 'NO display' }) (stop $($row.stopS) s, cycle $($row.cycleS) s)"
        }
        catch { $row.error = $_.Exception.Message; Step "[$c] FAILED: $($_.Exception.Message)" }
        finally {
            $rows.Add([pscustomobject]$row)
            Stop-VM -Name $name -TurnOff -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 3
            if (Get-VM -Name $name -ErrorAction SilentlyContinue) { Remove-GpuVM -Name $name -DeleteDisk -Confirm:$false | Out-Null }
        }
    }
    $ok = @($rows | Where-Object { $_.afterCycle }).Count
    $badBefore = @($rows | Where-Object { $_.PSObject.Properties['beforeCycle'] -and -not $_.beforeCycle }).Count
    Step "done: after the cold cycle $ok of $($rows.Count) copies have their display; without it $badBefore had none"
}
finally {
    $rows | ConvertTo-Json -Depth 4 | Set-Content $outFile
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Step "results: $outFile; lock released"
}
