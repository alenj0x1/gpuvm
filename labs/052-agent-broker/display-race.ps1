# Lab 052: copies of agent-tpl whose agent sees no display after the install restart (agent-guest 2026-11-19: 2 of
# 5). The installed build, one copy at a time (3 GB): make it, start it, Install-GpuVMAgent (as a claim does), then
# follow agent.info's displays for -WatchSec. A copy with none after -RepairAfterSec gets its display adapters dumped
# and repairs tried in order (Hyper-V Video on again; the virtual display's device off and on), each followed by
# agent.info, to learn which one brings the screen back. Every copy is deleted. Under the shared lab lock. Elevated.
param([string]$Template = 'agent-tpl', [string]$Session = 'agent-broker', [int]$Copies = 10, [int]$WatchSec = 90,
    [int]$RepairAfterSec = 60, [int]$StopAfterFailures = 0,
    # -Branch: this worktree's module (Install-GpuVMAgent power cycles), with the installed agent package read-only.
    [switch]$Branch)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$installedRoot = Join-Path $env:ProgramFiles 'GpuVM\gpuvm'
$module = if ($Branch) { Join-Path $root 'src\GpuVM\GpuVM.psd1' } else { Join-Path $installedRoot 'src\GpuVM\GpuVM.psd1' }
function Line($what) { Write-Host "$(Get-Date -Format HH:mm:ss.fff) $what" }
$runs = [System.Collections.Generic.List[object]]::new()
$adapters = { @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FriendlyName): $($_.Status) [$($_.ConfigManagerErrorCode)]" }) }
# Where the agent's processes run, and what Windows says each adapter shows (resolution 0 = no desktop on it).
$where = {
    [ordered]@{
        agentProcesses = @(Get-CimInstance Win32_Process -Filter "Name='gpuvm-agent.exe'" | ForEach-Object { $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner; "pid $($_.ProcessId) session $($_.SessionId) $($o.User) $($_.CommandLine)" })
        sessions = @((quser 2>&1) | ForEach-Object { "$_" })
        video = @(Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name): $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)" })
        service = "$((Get-Service GpuVMAgent -ErrorAction SilentlyContinue).Status)"
    }
}
function Get-Displays($vmName) {
    $r = try { Invoke-GpuVMAgent -Name $vmName -Method agent.info -TimeoutSec 10 } catch { $null }
    if ($r -and $r.ok) { @($r.result.displays) } else { $null }
}
& (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What "lab 052: display race on $Copies copies of $Template" -Me $Session -MaxMinutes 120
if ($LASTEXITCODE) { throw 'no lock' }
try {
    Import-Module $module -Force
    $m = Get-Module GpuVM
    if ($Branch) {
        & $m {
            param($dist)
            $script:LabDist = $dist
            function script:Get-RepoPath { param($Relative) if ($Relative -eq 'guest\agent') { $script:LabDist } else { Join-Path $script:RepoRoot $Relative } }
        } (Join-Path $installedRoot 'guest\agent')
    }
    for ($i = 1; $i -le $Copies; $i++) {
        $vmName = "agent052r$i"
        $run = [ordered]@{ n = $i; name = $vmName; events = [System.Collections.Generic.List[string]]::new() }
        function Note($what) { $run['events'].Add("$(Get-Date -Format HH:mm:ss.fff) $what"); Line "[$i] $what" }
        $made = $false
        try {
            if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) { Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $vmName -DeleteDisk -Confirm:$false }
            New-GpuVM -Name $vmName -Template $Template | Out-Null
            $made = $true
            Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $false -StartupBytes 3GB
            Start-VM -Name $vmName
            $state = & $m { param($n) Get-GpuVMState -Name $n } $vmName
            $cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
            & $m { param($n, $c) Wait-GuestReady -Name $n -Credential $c } $vmName $cred
            $run['adaptersBeforeInstall'] = @(Invoke-Command -VMName $vmName -Credential $cred $adapters)
            $inst = Install-GpuVMAgent -Name $vmName
            Note "installed (restarted $($inst.restarted), $($inst.ms.total) ms)"
            $t0 = Get-Date
            $first = $null
            $repairs = [System.Collections.Generic.List[string]]::new()
            $tried = 0
            $lastState = ''
            while (((Get-Date) - $t0).TotalSeconds -lt $WatchSec + 60 * $tried) {
                $d = Get-Displays $vmName
                $sec = [math]::Round(((Get-Date) - $t0).TotalSeconds)
                # What the service says (asking it is also what starts its automatic repair).
                $ga = try { @(Get-GpuVMAgent -Name $vmName)[0] } catch { $null }
                if ($ga -and "$($ga.state)" -ne $lastState) {
                    $lastState = "$($ga.state)"
                    Note "service: $lastState $(if ($ga.lastError) { "- $($ga.lastError)" })"
                    $run['states'] = @($run['states']) + "$sec s: $lastState"
                }
                if ($d -and $d.Count) { $first = $sec; Note "displays after $sec s: $(($d | ForEach-Object { "$($_.adapter) $($_.rect -join ',')" }) -join '; ')"; break }
                if ($sec -ge $RepairAfterSec + 30 * $tried -and $tried -lt 3) {
                    $guestNow = try { @(Invoke-Command -VMName $vmName -Credential $cred $adapters) } catch { @("unreachable: $($_.Exception.Message)") }
                    $run["adaptersAt$sec"] = $guestNow
                    $run["consoleAt$sec"] = try { Invoke-Command -VMName $vmName -Credential $cred { (Get-CimInstance Win32_ComputerSystem).UserName } } catch { $null }
                    Note "no display after $sec s; adapters: $($guestNow -join '; '); console $($run["consoleAt$sec"])"
                    $run["whereAt$sec"] = try { Invoke-Command -VMName $vmName -Credential $cred $where } catch { "unreachable" }
                    Note "where: $($run["whereAt$sec"] | ConvertTo-Json -Compress -Depth 3)"
                    $full = try { Invoke-GpuVMAgent -Name $vmName -Method agent.info -TimeoutSec 10 } catch { $null }
                    $run["agentInfoAt$sec"] = $full
                    Note "agent.info: $($full.result | ConvertTo-Json -Compress -Depth 4)"
                    if ($tried -eq 0) {
                        $r = try { Invoke-Command -VMName $vmName -Credential $cred { Restart-Service GpuVMAgent -Force; 'restarted' } } catch { "failed: $($_.Exception.Message)" }
                        $repairs.Add("agent-service:$r"); Note "repair 1: the agent's service restarted -> $r"
                    }
                    elseif ($tried -eq 1) {
                        $r = try {
                            Invoke-Command -VMName $vmName -Credential $cred {
                                $user = (Get-CimInstance Win32_ComputerSystem).UserName
                                $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\DisplaySwitch.exe" -Argument '/extend'
                                $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
                                Register-ScheduledTask -TaskName 'Lab052-DisplaySwitch' -Action $action -Principal $principal -Force | Out-Null
                                Start-ScheduledTask -TaskName 'Lab052-DisplaySwitch'; Start-Sleep 3
                                Unregister-ScheduledTask -TaskName 'Lab052-DisplaySwitch' -Confirm:$false; 'extended'
                            }
                        } catch { "failed: $($_.Exception.Message)" }
                        $repairs.Add("displayswitch:$r"); Note "repair 2: DisplaySwitch /extend in the console -> $r"
                    }
                    else {
                        $r = try { Restart-VM -Name $vmName -Force -Wait -For Heartbeat -Timeout 300; 'rebooted' } catch { "failed: $($_.Exception.Message)" }
                        $repairs.Add("reboot:$r"); Note "repair 3: Windows restarted -> $r"
                    }
                    $tried++
                }
                Start-Sleep -Seconds 2
            }
            $run['firstDisplaySec'] = $first
            $run['repairs'] = @($repairs)
            $run['ok'] = $null -ne $first
            if (-not $run['ok']) { Note "still no display" }
            $failures = @($runs | Where-Object { $_.repairs.Count }).Count + [int]([bool]$repairs.Count)
        }
        catch { $run['error'] = "$($_.Exception.Message)"; Note "ERROR $($run['error'])" }
        finally {
            if ($made) { try { Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $vmName -DeleteDisk -Confirm:$false } catch { Line "couldn't delete $vmName : $($_.Exception.Message)" } }
            $run['events'] = @($run['events'])
            $runs.Add($run)
            $runs | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out "display-race-$stamp.json") -Encoding utf8
        }
        if ($StopAfterFailures -and @($runs | Where-Object { $_.repairs.Count }).Count -ge $StopAfterFailures) { Line "stopping: $StopAfterFailures copies without a display"; break }
    }
    $bad = @($runs | Where-Object { -not $_.ok -or $_.repairs.Count })
    Line "done: $($runs.Count) copies, $($bad.Count) without a display at first; repairs that worked: $(($runs | Where-Object { $_.ok -and $_.repairs.Count } | ForEach-Object { $_.repairs[-1] }) -join ', ')"
}
finally {
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Line 'lock released'
}
