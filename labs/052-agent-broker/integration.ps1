# Lab 052, real VMs with the INSTALLED GpuVM (service broker + module + guest agent from the same build), all under
# one hold of the shared lab lock:
#   1. agent051 (Off, no secret): start, Install-GpuVMAgent (full), again (same version: fast path), the display the
#      agent sees and Set-GpuVMUse's 1280x800 (the 1024x768 question).
#   2. run.ps1 -Real on agent051: latency, parallel, timeout, attacks (stub copied into the guest), offers, restart.
#   3. Service restarts: how fast the real agent is back.
#   4. agent051 off again; two small disposables of agent-tpl at once (New-GpuVM -Use agent: create, wait, install),
#      requests to both in parallel, each answer checked against its machine; then both deleted.
# Run elevated. Nothing of another session's VM is touched; agent051 ends Off as it was.
param([string]$Session = 'agent-broker', [string]$Name = 'agent051', [string]$Template = 'agent-tpl', [int]$Rounds = 2,
    [string[]]$Steps = @('install', 'parts', 'service', 'two'))
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$modulePath = Join-Path $env:ProgramFiles 'GpuVM\gpuvm\src\GpuVM\GpuVM.psd1'
$out = Join-Path $PSScriptRoot 'out'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$result = [ordered]@{ started = (Get-Date).ToString('o') }
function Save { $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $out "integration-$stamp.json") -Encoding utf8 }
function Line($what) { "$(Get-Date -Format HH:mm:ss) $what" }

& (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What "lab 052: broker integration on $Name and two $Template disposables" -Me $Session -MaxMinutes 300
if ($LASTEXITCODE) { throw 'no lock' }
$made = [System.Collections.Generic.List[string]]::new()
try {
    Import-Module $modulePath -Force
    . (Join-Path $root 'tools\latency\common.ps1')
    if ((Get-Service GpuVM).Status -ne 'Running') { Start-Service GpuVM }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $(try { (Get-GpuVMAgentBroker).listening } catch { $false }) -and $sw.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 100 }
    $result['broker'] = Get-GpuVMAgentBroker
    Line "broker: $($result['broker'] | ConvertTo-Json -Compress)"
    $cred = (Get-LatencyVM -Name $Name).Guest
    $guest = { param([scriptblock]$b, $a = @()) Invoke-Command -VMName $Name -Credential $cred -ErrorAction Stop -ScriptBlock $b -ArgumentList $a }
    function Wait-Ready([string]$vm, [double]$sec, [long]$after = 0) {
        $w = [Diagnostics.Stopwatch]::StartNew()
        while ($w.Elapsed.TotalSeconds -lt $sec) {
            $a = try { @(Get-GpuVMAgent -Name $vm)[0] } catch { $null }
            if ($a -and $a.state -eq 'ready' -and [long]$a.connectedSince -gt $after) { return [math]::Round($w.Elapsed.TotalMilliseconds) }
            Start-Sleep -Milliseconds 100
        }
        $null
    }

    if ('install' -in $Steps) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        if ((Get-VM -Name $Name).State -ne 'Running') { Start-VM -Name $Name }
        while ($sw.Elapsed.TotalMinutes -lt 10) { try { & $guest { 1 } | Out-Null; break } catch { Start-Sleep -Milliseconds 500 } }
        $result['psDirectAfterStartMs'] = [math]::Round($sw.Elapsed.TotalMilliseconds)
        Line "PowerShell Direct after $($result['psDirectAfterStartMs']) ms"
        $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $r = Install-GpuVMAgent -Name $Name
        $result['install'] = [ordered]@{ result = $r; readyMs = (Wait-Ready $Name 300 $t0) }
        Line "install: $($result['install'] | ConvertTo-Json -Compress -Depth 5)"
        $t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $r2 = Install-GpuVMAgent -Name $Name
        $result['installAgain'] = [ordered]@{ result = $r2; readyMs = (Wait-Ready $Name 300 $t1) }
        Line "install again: $($result['installAgain'] | ConvertTo-Json -Compress -Depth 5)"
        $result['hostSecretReadableByAdmin'] = try { [IO.File]::ReadAllBytes((Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "GpuVM\agents\$($r.vmId)\secret")) | Out-Null; $true } catch { $false }
        $result['guestSecret'] = & $guest {
            $acl = Get-Acl 'C:\ProgramData\GpuVM\Agent\secret'
            [pscustomobject]@{ size = (Get-Item 'C:\ProgramData\GpuVM\Agent\secret').Length
                sids = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique)
                gsi = $null }
        }
        $result['gsiEnabled'] = (Get-VMIntegrationService -VMName $Name | Where-Object { $_.Id -like '*6C09BB55-D683-4DA0-8931-C9BF705F6480' }).Enabled
        # The display the agent's session sees, and what the guest's video adapters say, before and after 1280x800.
        $display = {
            $info = (Invoke-GpuVMAgent -Name $Name -Method agent.info).result
            $adapters = & $guest { @(Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name): $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution) $($_.Status)" }) }
            [ordered]@{ agentScreen = $info.screen; user = $info.user; session = $info.session; home = $info.home; adapters = @($adapters)
                consoleUser = (& $guest { (Get-CimInstance Win32_ComputerSystem).UserName }) }
        }
        $result['displayBefore'] = & $display
        Line "display before: $($result['displayBefore'] | ConvertTo-Json -Compress -Depth 4)"
        $use = Set-GpuVMUse -Name $Name -Use agent
        $result['setUse'] = $use
        Start-Sleep -Seconds 2
        $result['displayAfter'] = & $display
        Line "display after Set-GpuVMUse: $($result['displayAfter'] | ConvertTo-Json -Compress -Depth 4)"
        Save
    }

    if ('parts' -in $Steps) {
        Wait-Ready $Name 300 | Out-Null
        $parts = "'latency','parallel','timeout','attacks','offers','restart'"
        pwsh -NoProfile -Command "& '$PSScriptRoot\run.ps1' -Name $Name -Real -ModulePath '$modulePath' -Parts $parts -Rounds $Rounds" 2>&1 |
            Where-Object { $_ -notmatch '^saved' } | ForEach-Object { Line $_ }
    }

    if ('service' -in $Steps) {
        Wait-Ready $Name 300 | Out-Null
        $rows = for ($i = 0; $i -lt 3; $i++) {
            Start-Sleep -Seconds 2
            $t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $w = [Diagnostics.Stopwatch]::StartNew()
            Restart-Service GpuVM
            $restart = $w.Elapsed.TotalMilliseconds
            $ready = Wait-Ready $Name 60 $t
            [ordered]@{ restartMs = [math]::Round($restart); agentReadyMs = if ($ready) { [math]::Round($w.Elapsed.TotalMilliseconds) } }
        }
        $result['serviceRestarts'] = @($rows)
        Line "service restarts: $(@($rows) | ConvertTo-Json -Compress)"
        Save
    }

    if ('two' -in $Steps) {
        # agent051 goes off (as it was) so two small copies fit in memory.
        try { & $guest { Stop-Computer -Force } } catch { }
        $w = [Diagnostics.Stopwatch]::StartNew()
        while ((Get-VM -Name $Name).State -ne 'Off' -and $w.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Seconds 1 }
        if ((Get-VM -Name $Name).State -ne 'Off') { Stop-VM -Name $Name -Force }
        $copies = foreach ($n in 'agent052a', 'agent052b') {
            $w = [Diagnostics.Stopwatch]::StartNew()
            try { New-GpuVM -Name $n -Template $Template -Disposable -Override @{ vm = @{ memoryGB = 2 } } -Use agent | Out-Null }
            catch { Line "$n : $($_.Exception.Message)"; if (Get-VM -Name $n -ErrorAction SilentlyContinue) { $made.Add($n) }; continue }
            $made.Add($n)
            $ms = [math]::Round($w.Elapsed.TotalMilliseconds)
            $ready = Wait-Ready $n 300
            $a = @(Get-GpuVMAgent -Name $n)[0]
            Line "$n created and agent installed in $ms ms, ready +$ready ms, state $($a.state)"
            [ordered]@{ name = $n; createAndInstallMs = $ms; readyMs = $ready; state = $a.state; vmId = $a.vmId; version = $a.version }
        }
        $result['disposables'] = @($copies)
        $want = @{}
        foreach ($c in $copies) { $want[$c.name] = $c.vmId }
        $both = @(Get-GpuVMAgent | Where-Object { $_.state -eq 'ready' -and $_.name -in $want.Keys }).name
        $runs = foreach ($m in $want.Keys) { foreach ($k in 1..4) { [pscustomobject]@{ Machine = $m } } }
        $w = [Diagnostics.Stopwatch]::StartNew()
        $all = $runs | ForEach-Object -ThrottleLimit 8 -Parallel {
            $p = [IO.Pipes.NamedPipeClientStream]::new('.', 'gpuvm-agent', [IO.Pipes.PipeDirection]::InOut); $p.Connect(3000)
            $r = [IO.StreamReader]::new($p); $wr = [IO.StreamWriter]::new($p)
            $times = [System.Collections.Generic.List[double]]::new(); $fails = 0
            for ($i = 0; $i -lt 100; $i++) {
                $t = [Diagnostics.Stopwatch]::StartNew()
                $wr.Write((@{ id = $i; cmd = 'Invoke-GpuVMAgent'; args = @{ Name = $_.Machine; Method = 'agent.info' } } | ConvertTo-Json -Compress) + "`n"); $wr.Flush()
                $d = ($r.ReadLine() | ConvertFrom-Json).data[0]
                $times.Add($t.Elapsed.TotalMilliseconds)
                if (-not $d.ok) { $fails++ }
            }
            $p.Dispose()
            [pscustomobject]@{ machine = $_.Machine; times = $times.ToArray(); fails = $fails }
        }
        $wall = $w.Elapsed.TotalMilliseconds
        $two = [ordered]@{ readyAtOnce = $both; wallMs = [math]::Round($wall) }
        foreach ($g in $all | Group-Object machine) {
            $s = @($g.Group.times) | ForEach-Object { [double]$_ } | Sort-Object
            $two[$g.Name] = [ordered]@{ requests = $s.Count; failed = ($g.Group | Measure-Object fails -Sum).Sum
                p50 = [math]::Round($s[[int]($s.Count / 2)], 2); p95 = [math]::Round($s[[int]($s.Count * 0.95)], 2) }
        }
        # Each machine's log has only its own requests (routing by the accepted VmId).
        foreach ($c in $copies) {
            $log = Join-Path (Get-VM -Name $c.name).Path 'agent.log'
            $two["$($c.name)LogRequests"] = @(Get-Content $log | Where-Object { $_ -match '"method":"agent.info"' }).Count
        }
        $result['twoAtOnce'] = $two
        Line "two at once: $($two | ConvertTo-Json -Compress -Depth 4)"
        Save
    }
}
finally {
    foreach ($n in $made) {
        try { Stop-VM -Name $n -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $n -DeleteDisk -Confirm:$false -ErrorAction Stop; Line "$n deleted" }
        catch { Line "couldn't delete $n : $($_.Exception.Message)" }
    }
    if ((Get-VM -Name $Name -ErrorAction SilentlyContinue).State -eq 'Running') {
        try { & $guest { Stop-Computer -Force } } catch { }
        $w = [Diagnostics.Stopwatch]::StartNew()
        while ((Get-VM -Name $Name).State -ne 'Off' -and $w.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Seconds 1 }
        if ((Get-VM -Name $Name).State -ne 'Off') { Stop-VM -Name $Name -Force }
    }
    $result['finished'] = (Get-Date).ToString('o')
    Save
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Line 'lock released'
}
