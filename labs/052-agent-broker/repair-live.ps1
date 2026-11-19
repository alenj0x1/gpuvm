# Lab 052: the service's automatic display repair, for real. Copies of agent-tpl (installed build, 3 GB each, one at a
# time) get the agent, then Windows is restarted from inside (a restart keeps the GPU partition's state, which is how
# copies ended without a display) until a boot comes up where the agent reports noDisplay. While looking, only
# agent.info is asked (Get-GpuVMAgent is what starts the repair). Then nothing is touched: Get-GpuVMAgent is asked every
# 2 s and its states are timed until "ready" with a display, or -RepairWatchSec. Everything is deleted at the end.
# Under the shared lab lock. Run elevated.
param([string]$Template = 'agent-tpl', [string]$Session = 'agent-broker', [int]$BudgetMinutes = 30, [int]$RestartsPerCopy = 4,
    [int]$RepairWatchSec = 600)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$module = Join-Path $env:ProgramFiles 'GpuVM\gpuvm\src\GpuVM\GpuVM.psd1'
function Line($what) { Write-Host "$(Get-Date -Format HH:mm:ss.fff) $what" }
$result = [ordered]@{ boots = [System.Collections.Generic.List[object]]::new(); repair = $null }
function Get-Info($vmName) { try { $r = Invoke-GpuVMAgent -Name $vmName -Method agent.info -TimeoutSec 10; if ($r.ok) { $r.result } } catch { $null } }
& (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What "lab 052: the automatic display repair, live" -Me $Session -MaxMinutes 120
if ($LASTEXITCODE) { throw 'no lock' }
$made = [System.Collections.Generic.List[string]]::new()
$deadline = (Get-Date).AddMinutes($BudgetMinutes)
try {
    Import-Module $module -Force
    $m = Get-Module GpuVM
    $copy = 0
    $found = $null
    while (-not $found -and (Get-Date) -lt $deadline) {
        $copy++
        $vmName = "agent052x$copy"
        New-GpuVM -Name $vmName -Template $Template | Out-Null
        $made.Add($vmName)
        Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $false -StartupBytes 3GB
        Start-VM -Name $vmName
        $cred = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $vmName
        & $m { param($n, $c) Wait-GuestReady -Name $n -Credential $c } $vmName $cred
        Install-GpuVMAgent -Name $vmName | Out-Null
        for ($r = 0; $r -le $RestartsPerCopy -and -not $found -and (Get-Date) -lt $deadline; $r++) {
            if ($r -gt 0) {
                # From inside, like the old install did.
                Invoke-Command -VMName $vmName -Credential $cred { Restart-Computer -Force } -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 15
            }
            $t0 = Get-Date
            $info = $null
            while (((Get-Date) - $t0).TotalSeconds -lt 60) {
                $info = Get-Info $vmName
                if ($info -and $info.signedIn -and (@($info.displays).Count -or $info.noDisplay)) { break }
                Start-Sleep -Seconds 2
            }
            $boot = [ordered]@{ copy = $vmName; restart = $r; displays = @($info.displays).Count; noDisplay = $info.noDisplay; sec = [math]::Round(((Get-Date) - $t0).TotalSeconds) }
            $result['boots'].Add($boot)
            Line "$vmName boot ${r}: displays $($boot.displays), noDisplay '$($boot.noDisplay)'"
            if ($info -and ($info.noDisplay -or -not @($info.displays).Count)) { $found = $vmName }
        }
        if (-not $found) {
            Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue
            Remove-GpuVM -Name $vmName -DeleteDisk -Confirm:$false
            $made.Remove($vmName) | Out-Null
        }
    }
    if ($found) {
        # Hands off: only Get-GpuVMAgent, every 2 s.
        $t0 = Get-Date
        $timeline = [System.Collections.Generic.List[string]]::new()
        $last = ''
        $ended = $null
        while (((Get-Date) - $t0).TotalSeconds -lt $RepairWatchSec) {
            $a = try { @(Get-GpuVMAgent -Name $found)[0] } catch { $null }
            $now = "$($a.state)"
            if ($now -ne $last) {
                $sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
                $timeline.Add("$sec s: $now$(if ($a.lastError) { " - $($a.lastError)" })")
                Line "$found $sec s: $now $(if ($a.lastError) { "- $($a.lastError)" })"
                $last = $now
            }
            if ($now -eq 'ready' -and @($a.agent.displays).Count) { $ended = 'ready'; break }
            if ($now -eq 'no-display') { $ended = 'no-display'; break }
            Start-Sleep -Seconds 2
        }
        $result['repair'] = [ordered]@{ machine = $found; ended = $ended; sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1); timeline = @($timeline)
            displays = @((Get-Info $found).displays) }
        Line "repair: $ended after $($result['repair'].sec) s; displays $($result['repair'].displays | ConvertTo-Json -Compress -Depth 3)"
    }
    else { Line "no copy came up without a display in $BudgetMinutes min ($copy copies)" }
}
catch { $result['error'] = "$($_.Exception.Message)"; Line "ERROR $($result['error'])" }
finally {
    foreach ($n in @($made)) {
        try { Stop-VM -Name $n -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $n -DeleteDisk -Confirm:$false; Line "$n deleted" }
        catch { Line "couldn't delete $n : $($_.Exception.Message)" }
    }
    $result['boots'] = @($result['boots'])
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out "repair-live-$stamp.json") -Encoding utf8
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Line 'lock released'
}
