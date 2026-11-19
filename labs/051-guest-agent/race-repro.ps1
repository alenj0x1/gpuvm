# Copies of agent-tpl whose agent sees NO display (agent-broker: 4 of 13, persistent). Makes copies one at a time
# (installed build) until one is bad (no display 60 s after the install's restart) or -Copies is reached. On a bad
# copy: installs guest/agent/dist (0.4.3: agent.info carries a display diagnosis) and dumps what the helper sees
# (devices + flags, active CCD paths, its window station\desktop, the last layout result), what a separate process of
# the agent user sees (gpuvm-agent diag), the agent log, and keeps nothing. One lab lock for the whole run.
param([string]$Template = 'agent-tpl', [int]$Copies = 8, [string]$Me = 'agent-guest', [switch]$KeepBad)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$outDir = Join-Path $PSScriptRoot ('out\race-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $outDir | Out-Null
Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
function Step($m) { "[$(Get-Date -Format HH:mm:ss)] $m" | Out-Host }
function Info([string]$n) { try { (Invoke-GpuVMAgent -Name $n -Method agent.info -TimeoutSec 5).result } catch { $null } }
& (Join-Path $repo 'labs\042-admin-dock\take-lock.ps1') -What "lab 051: display race repro ($Copies copies of $Template)" -Me $Me -MaxMinutes 240
if ($LASTEXITCODE -ne 0) { throw 'no lock' }
$bad = 0
try {
    for ($c = 1; $c -le $Copies; $c++) {
        $name = "a051r$c"
        # the claim path (agent-broker's lab 052, where 4 of 13 went bad): copy, start, Install-GpuVMAgent with its restart
        New-GpuVM -Name $name -Template $Template | Out-Null
        Set-VMMemory -VMName $name -DynamicMemoryEnabled $false -StartupBytes 3GB
        Start-VM -Name $name
        $m = Get-Module GpuVM
        $gc0 = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $name
        & $m { param($n, $c) Wait-GuestReady -Name $n -Credential $c } $name $gc0
        $inst = Install-GpuVMAgent -Name $name
        Step "[$c] installed (restarted $($inst.restarted), $($inst.ms.total) ms)"
        # @($null).Count is 1: an answer without a displays field must not count as a display (the first run did)
        $sw = [Diagnostics.Stopwatch]::StartNew(); $i = $null
        function HasDisplay($x) { $x -and $null -ne $x.displays -and @($x.displays | Where-Object { $_.adapter }).Count -ge 1 }
        do { Start-Sleep -Seconds 2; $i = Info $name } until ((HasDisplay $i) -or $sw.Elapsed.TotalSeconds -gt 60)
        if (HasDisplay $i) {
            Step "[$c] ok: $(@($i.displays | ForEach-Object { "$($_.adapter) $($_.rect -join ',')" }) -join ' | ') after $([int]$sw.Elapsed.TotalSeconds) s"
        } else {
            $bad++
            Step "[$c] BAD: no display after 60 s (agent $($i.version))"
            $gc = & (Get-Module GpuVM) { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $name
            $s = New-PSSession -VMName $name -Credential $gc
            $before = Invoke-Command -Session $s { Get-Content C:\ProgramData\GpuVM\Agent\logs\agent.log -Encoding UTF8 | Select-Object -Last 30 }
            Set-Content (Join-Path $outDir "copy$c-log-before.txt") $before
            # 0.4.3 with the diagnosis (the bad state survives a helper restart, agent-broker)
            $staging = 'C:\ProgramData\GpuVM\Agent\staging'
            Invoke-Command -Session $s { param($d) New-Item -ItemType Directory $d -Force | Out-Null } -ArgumentList $staging
            Get-ChildItem (Join-Path $repo 'guest\agent\dist') | ForEach-Object { Copy-Item $_.FullName -Destination $staging -ToSession $s -Force }
            $r = Invoke-Command -Session $s -FilePath (Join-Path $repo 'guest\agent\install.ps1') -ArgumentList $staging
            $sw.Restart(); do { Start-Sleep -Seconds 2; $i = Info $name } until (($i -and $i.diag) -or $sw.Elapsed.TotalSeconds -gt 60)
            Start-Sleep -Seconds 12
            $i = Info $name
            $sep = Invoke-Command -Session $s {
                $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c "C:\Program Files\GpuVM Agent\gpuvm-agent.exe" diag > C:\Users\Public\lab051-diag.json 2>&1'
                $p = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\agent" -LogonType Interactive -RunLevel Limited
                Register-ScheduledTask -TaskName Lab051Diag -Action $a -Principal $p -Force | Out-Null
                Start-ScheduledTask -TaskName Lab051Diag
                $t = 0; do { Start-Sleep -Milliseconds 500; $t++ } while ((Get-ScheduledTask -TaskName Lab051Diag).State -eq 'Running' -and $t -lt 60)
                Unregister-ScheduledTask -TaskName Lab051Diag -Confirm:$false
                Get-Content C:\Users\Public\lab051-diag.json -Raw -ErrorAction SilentlyContinue
            }
            $after = Invoke-Command -Session $s { Get-Content C:\ProgramData\GpuVM\Agent\logs\agent.log -Encoding UTF8 | Select-Object -Last 15 }
            Remove-PSSession $s
            $dump = [ordered]@{ copy = $c; installedAfter = $r.version; helperInfo = $i; separateProcessDiag = $sep; logAfter = $after }
            $dump | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $outDir "copy$c-dump.json")
            Step "[$c] agent $($i.version) noDisplay: $($i.noDisplay)"
            Step "[$c] helper diag: $($i.diag | ConvertTo-Json -Compress -Depth 6)"
            Step "[$c] separate process: $sep"
            if ($KeepBad) { Step "[$c] kept for inspection"; break }
        }
        if (-not $KeepBad -or $bad -eq 0) { Stop-VM -Name $name -TurnOff -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 3; if (Get-VM -Name $name -ErrorAction SilentlyContinue) { Remove-GpuVM -Name $name -DeleteDisk -Confirm:$false | Out-Null } }
        if ($bad -ge 1) { break }
    }
    Step "done: $bad bad of $c copies"
}
finally {
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Step "results: $outDir; lock released"
}
