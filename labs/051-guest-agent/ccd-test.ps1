# Can a copy whose agent sees no display (0 active CCD paths, every display device detached: race-repro, 2 of 10) get
# its display back from the agent's session? Copies agent-tpl the claim way (copy, start, Install-GpuVMAgent with its
# restart) until one is bad; on a good one, a look only (for comparison); on the bad one, the harness as the agent user:
# probe, then `all` (activate the virtual display's path from QDC_ALL_PATHS; SDC_TOPOLOGY_EXTEND only if still
# nothing), then what the agent reports. One lab lock for the whole run; every copy is deleted.
param([string]$Template = 'agent-tpl', [int]$Copies = 12, [string]$Me = 'agent-guest', [ValidateSet('all', 'retry', 'extend')][string]$Fix = 'all')
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$outDir = Join-Path $PSScriptRoot ('out\ccd-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $outDir | Out-Null
Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
$m = Get-Module GpuVM
function Step($t) { "[$(Get-Date -Format HH:mm:ss)] $t" | Out-Host }
function Info([string]$n) { try { (Invoke-GpuVMAgent -Name $n -Method agent.info -TimeoutSec 5).result } catch { $null } }
function HasDisplay($x) { $x -and $null -ne $x.displays -and @($x.displays | Where-Object { $_.adapter }).Count -ge 1 }
function Ccd($s, [string]$what) {
    Invoke-Command -Session $s {
        param($w)
        Remove-Item C:\Users\Public\lab051-ccd.json -ErrorAction SilentlyContinue
        $a = New-ScheduledTaskAction -Execute 'C:\Users\Public\lab051-harness.exe' -Argument "guest-ccd $w"
        $p = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\agent" -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName Lab051Ccd -Action $a -Principal $p -Force | Out-Null
        Start-ScheduledTask -TaskName Lab051Ccd
        $t = 0; do { Start-Sleep -Milliseconds 500; $t++ } while (-not (Test-Path C:\Users\Public\lab051-ccd.json) -and $t -lt 60)
        Start-Sleep -Milliseconds 300
        Unregister-ScheduledTask -TaskName Lab051Ccd -Confirm:$false
        Get-Content C:\Users\Public\lab051-ccd.json -Raw -ErrorAction SilentlyContinue
    } -ArgumentList $what
}
& (Join-Path $repo 'labs\042-admin-dock\take-lock.ps1') -What "lab 051: no-display copies, can the session turn the display on ($Copies copies of $Template)" -Me $Me -MaxMinutes 240
if ($LASTEXITCODE -ne 0) { throw 'no lock' }
$lookedGood = $false; $bad = 0
try {
    for ($c = 1; $c -le $Copies; $c++) {
        $name = "a051c$c"
        try {
            New-GpuVM -Name $name -Template $Template | Out-Null
            Set-VMMemory -VMName $name -DynamicMemoryEnabled $false -StartupBytes 3GB
            Start-VM -Name $name
            $gc = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $name
            & $m { param($n, $cr) Wait-GuestReady -Name $n -Credential $cr } $name $gc
            $inst = Install-GpuVMAgent -Name $name
            $sw = [Diagnostics.Stopwatch]::StartNew(); $i = $null
            do { Start-Sleep -Seconds 2; $i = Info $name } until ((HasDisplay $i) -or $sw.Elapsed.TotalSeconds -gt 60)
            $ok = HasDisplay $i
            Step "[$c] installed (restarted $($inst.restarted)); $(if ($ok) { "ok: $(@($i.displays | ForEach-Object { "$($_.adapter) $($_.rect -join ',')" }) -join ' | ')" } else { 'BAD: no display after 60 s' })"
            if ($ok -and $lookedGood) { continue }
            $s = New-PSSession -VMName $name -Credential $gc
            Copy-Item (Join-Path $PSScriptRoot 'harness\target\release\harness.exe') -Destination 'C:\Users\Public\lab051-harness.exe' -ToSession $s -Force
            if ($ok) {
                $look = Ccd $s 'probe'; Set-Content (Join-Path $outDir "copy$c-good-probe.json") $look
                Step "[$c] good copy looks like: $look"
                $lookedGood = $true
            } else {
                $bad++
                $look = Ccd $s 'probe'; Set-Content (Join-Path $outDir "copy$c-bad-probe.json") $look
                Step "[$c] bad copy looks like: $look"
                $procs = Invoke-Command -Session $s {
                    "power (display off after, AC s): $((powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE | Select-String 'Índice de configuración de corriente alterna actual|Current AC Power Setting Index' | Out-String).Trim())"
                    "power requests: $((powercfg /requests | Out-String).Trim() -replace '\s+', ' ')"
                    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
                    "events since boot: $((Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $boot } -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -match 'Power|Display|dxg|Winlogon|User32|Video|Iddcx|VDD' } | Sort-Object TimeCreated | ForEach-Object { "$($_.TimeCreated.ToString('HH:mm:ss')) $($_.ProviderName)#$($_.Id)" }) -join '; ')"
                    "boot: $($boot.ToString('HH:mm:ss')), now $(Get-Date -Format HH:mm:ss)"
                }
                Set-Content (Join-Path $outDir "copy$c-bad-procs.txt") $procs
                $procs | ForEach-Object { Step "[$c] $_" }
                # one cause at a time, each followed by a look: display asleep -> device restart -> layout retries
                $wake = Ccd $s 'wake'; Set-Content (Join-Path $outDir "copy$c-bad-wake.json") $wake
                Step "[$c] wake: $(($wake | ConvertFrom-Json).wake | ConvertTo-Json -Compress)"
                if (-not (($wake | ConvertFrom-Json).wake.activeEvery500ms | Where-Object { $_ -gt 0 })) {
                    $rd = Invoke-Command -Session $s {
                        $d = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match 'Virtual Display' } | Select-Object -First 1
                        if ($d) { "$($d.FriendlyName): $((pnputil /restart-device "$($d.InstanceId)" 2>&1 | Out-String).Trim() -replace '\s+', ' ')" } else { 'no virtual display device' }
                    }
                    Start-Sleep -Seconds 5
                    $look2 = Ccd $s 'probe'; Set-Content (Join-Path $outDir "copy$c-bad-after-restart.json") $look2
                    $act = ($look2 | ConvertFrom-Json).before.active
                    Step "[$c] restart of the virtual display device: $rd -> active $($act | ConvertTo-Json -Compress)"
                    if (-not $act.paths) {
                        $turnOn = Ccd $s $Fix; Set-Content (Join-Path $outDir "copy$c-bad-$Fix.json") $turnOn
                        Step "[$c] $Fix : $(($turnOn | ConvertFrom-Json).after.active | ConvertTo-Json -Compress) tries $((($turnOn | ConvertFrom-Json).retries).Count)"
                    }
                }
                function Watch([string]$after, [int]$sec = 30) {
                    $w = [Diagnostics.Stopwatch]::StartNew(); $x = $null
                    do { Start-Sleep -Seconds 2; $x = Info $name } until ((HasDisplay $x) -or $w.Elapsed.TotalSeconds -gt $sec)
                    $got = HasDisplay $x
                    Step "[$c] after $after : $(if ($got) { @($x.displays | ForEach-Object { "$($_.adapter) $($_.rect -join ',')" }) -join ' | ' } else { 'still no display' }) ($([int]$w.Elapsed.TotalSeconds) s)"
                    $got
                }
                $back = Watch 'wake / device restart / layout retries'
                # the session itself: the Hyper-V video device, reconnecting the session to the console, signing out
                # (autologon signs in again), restarting Windows
                if (-not $back) {
                    $o = Invoke-Command -Session $s {
                        $d = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match 'Hyper-V Video' } | Select-Object -First 1
                        if ($d) { (pnputil /restart-device "$($d.InstanceId)" 2>&1 | Out-String).Trim() -replace '\s+', ' ' } else { 'no Hyper-V video' }
                    }
                    Step "[$c] Hyper-V video restart: $o"
                    $back = Watch 'Hyper-V video restart'
                }
                if (-not $back) {
                    $o = Invoke-Command -Session $s { $id = (Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1).SessionId; "tscon $id -> $((tscon $id /dest:console 2>&1 | Out-String).Trim())" }
                    Step "[$c] $o"
                    $back = Watch 'tscon to the console'
                }
                if (-not $back) {
                    $o = Invoke-Command -Session $s { $id = (Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1).SessionId; "logoff $id -> $((logoff $id 2>&1 | Out-String).Trim())" }
                    Step "[$c] $o"
                    $back = Watch 'sign-out and autologon' 90
                    if (-not $back) { Step "[$c] sessions now: $(Invoke-Command -Session $s { (qwinsta 2>&1 | Out-String).Trim() -replace '\s+', ' ' })" }
                }
                if (-not $back) {
                    Remove-PSSession $s; $s = $null
                    Restart-VM -Name $name -Force
                    $back = Watch 'restarting Windows' 150
                }
            }
            if ($s) { Remove-PSSession $s }
        }
        catch { Step "[$c] FAILED: $($_.Exception.Message)" }
        finally {
            Stop-VM -Name $name -TurnOff -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 3
            if (Get-VM -Name $name -ErrorAction SilentlyContinue) { Remove-GpuVM -Name $name -DeleteDisk -Confirm:$false | Out-Null }
        }
        if ($bad -ge 2) { break }
    }
    Step "done: $bad bad copies looked at"
}
finally {
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Step "results: $outDir; lock released"
}
