# Lab 052, real VMs with the INSTALLED GpuVM (service broker + module + guest agent from the same build), all under
# one hold of the shared lab lock:
#   1. A disposable copy of agent-tpl (2 GB): Install-GpuVMAgent (the template has the agent: fast path), again, the
#      display the agent sees and Set-GpuVMUse's 1280x800 (the 1024x768 question).
#   2. run.ps1 -Real on it: latency, parallel, timeout, attacks (stub copied into the guest), offers, restart.
#   3. Service restarts: how fast the real agent is back.
#   4. A second copy made with New-GpuVM -Use agent (create, wait, install), requests to both in parallel, each
#      machine's log holding only its own requests.
# Run elevated. Only the copies this script makes are touched, and they are deleted at the end.
param([string]$Session = 'agent-broker', [string]$Name = 'agent052a', [string]$Template = 'agent-tpl', [int]$Rounds = 2,
    [string[]]$Steps = @('swap', 'install', 'parts', 'service', 'two', 'stop', 'mcp'),
    [string[]]$Leftovers = @(),
    [string]$RunParts = "'latency','parallel','timeout','attacks','offers','restart'")
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
$installedHost = Join-Path $env:ProgramFiles 'GpuVM\gpuvm-host.exe'
$installedAgentPs1 = Join-Path $env:ProgramFiles 'GpuVM\gpuvm\src\GpuVM\Private\Agent.ps1'
$backupDir = 'C:\GpuVM\lab052\installed'
# This branch's gpuvm-host, copied where only administrators can write, runs the bounded stop.
$boundedStop = 'C:\GpuVM\lab052\gpuvm-host-stop.exe'
function Remove-Copies {
    foreach ($n in @($made)) {
        try { Stop-VM -Name $n -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $n -DeleteDisk -Confirm:$false -ErrorAction Stop; Line "$n deleted" }
        catch { Line "couldn't delete $n : $($_.Exception.Message)" }
    }
    $made.Clear()
}
try {
    # Machines an earlier run of this lab left behind (named by the caller).
    foreach ($v in $Leftovers) { if (Get-VM -Name $v -ErrorAction SilentlyContinue) { $made.Add($v) } }
    if ($made.Count) { Import-Module $modulePath -Force; Remove-Copies }
    if ('swap' -in $Steps) {
        # This branch's service and module agent code replace the installed ones for the whole run (put back in the
        # finally): the run tests the latest broker, the secret stored by the service, and the bounded stop.
        & cargo build --release --manifest-path (Join-Path $root 'app\host\Cargo.toml') 2>&1 | Select-Object -Last 1
        if ($LASTEXITCODE) { throw 'build failed' }
        New-Item -ItemType Directory -Force $backupDir | Out-Null
        Copy-Item (Join-Path $root 'app\host\target\release\gpuvm-host.exe') $boundedStop -Force
        Copy-Item $installedHost, $installedAgentPs1 $backupDir -Force
        $script:swapped = $true
        # This branch's bounded stop (30 s, then the process): the installed one can wait up to 10 minutes.
        $w = [Diagnostics.Stopwatch]::StartNew()
        Start-Process $boundedStop -ArgumentList 'stop' -Wait -WindowStyle Hidden
        $result['swapStopMs'] = [math]::Round($w.Elapsed.TotalMilliseconds)
        Line "installed service stopped in $($result['swapStopMs']) ms ($((Get-Service GpuVM).Status))"
        Copy-Item (Join-Path $root 'app\host\target\release\gpuvm-host.exe') $installedHost -Force
        Copy-Item (Join-Path $root 'src\GpuVM\Private\Agent.ps1') $installedAgentPs1 -Force
        Start-Service GpuVM
        Line 'this branch''s gpuvm-host.exe and Agent.ps1 in place'
    }
    # common.ps1 imports this checkout's module: loaded first, then replaced by the installed one (one GpuVM module).
    . (Join-Path $root 'tools\latency\common.ps1')
    Get-Module GpuVM | Remove-Module -Force
    Import-Module $modulePath -Force
    if (@(Get-Module GpuVM).Count -ne 1) { throw 'more than one GpuVM module loaded' }
    if ((Get-Service GpuVM).Status -ne 'Running') { Start-Service GpuVM }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $(try { (Get-GpuVMAgentBroker).listening } catch { $false }) -and $sw.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 100 }
    $result['broker'] = Get-GpuVMAgentBroker
    Line "broker: $($result['broker'] | ConvertTo-Json -Compress)"
    # The machine under test: a copy of the template (not disposable: those start at once with the template's 8 GB).
    # GpuVM asks 4 GB per machine; this lab VM runs on 2 GB, set in Hyper-V only (deleted at the end), so two fit.
    function New-SmallCopy([string]$vm, [switch]$AgentUse) {
        $w = [Diagnostics.Stopwatch]::StartNew()
        if ($AgentUse) { New-GpuVM -Name $vm -Template $Template -Use agent | Out-Null } else { New-GpuVM -Name $vm -Template $Template | Out-Null }
        $made.Add($vm)
        Set-VMMemory -VMName $vm -DynamicMemoryEnabled $false -StartupBytes 2GB
        Start-VM -Name $vm
        [math]::Round($w.Elapsed.TotalMilliseconds)
    }
    $result['cloneMs'] = New-SmallCopy $Name
    Line "copy $Name of $Template made and started in $($result['cloneMs']) ms (2 GB)"
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
        $parts = $RunParts
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
        # The first copy is already up with its agent; the second one comes with New-GpuVM -Use agent.
        $first = @(Get-GpuVMAgent -Name $Name)[0]
        $copies = @([ordered]@{ name = $Name; vmId = $first.vmId; state = $first.state; version = $first.version })
        $copies += foreach ($n in @('agent052b')) {
            # New-GpuVM -Use agent on a machine that isn't on yet: the agent stays pending; Set-GpuVMUse installs it.
            $w = [Diagnostics.Stopwatch]::StartNew()
            try { New-SmallCopy $n -AgentUse | Out-Null }
            catch { Write-Host (Line "$n : $($_.Exception.Message)"); continue }
            $pending = (& (Get-Module GpuVM) { param($v) (Get-GpuVMState -Name $v)['agent'] } $n)
            $credB = (Get-LatencyVM -Name $n).Guest
            while ($w.Elapsed.TotalMinutes -lt 10) { try { Invoke-Command -VMName $n -Credential $credB { 1 } -ErrorAction Stop | Out-Null; break } catch { Start-Sleep -Milliseconds 500 } }
            $psd = [math]::Round($w.Elapsed.TotalMilliseconds)
            $use = Set-GpuVMUse -Name $n -Use agent
            $ms = [math]::Round($w.Elapsed.TotalMilliseconds)
            $ready = Wait-Ready $n 300
            $a = @(Get-GpuVMAgent -Name $n)[0]
            Write-Host (Line "${n}: pending=$($pending['pending']), PS Direct at $psd ms, agent use set at $ms ms, ready +$ready ms, state $($a.state)")
            [ordered]@{ name = $n; pendingBeforeStart = $pending['pending']; psDirectMs = $psd; useSetMs = $ms; readyMs = $ready; use = $use
                state = $a.state; vmId = $a.vmId; version = $a.version }
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


    if ('stop' -in $Steps) {
        # The bounded stop (48fa2d7): while a 60 s agent request runs, `gpuvm-host install` (what the installer does
        # over a running service) must stop the service in ~5 s, not 60.
        $job = Start-ThreadJob -ArgumentList $modulePath, $Name {
            param($m, $n)
            Import-Module $m -Force
            $w = [Diagnostics.Stopwatch]::StartNew()
            $r = try { Invoke-GpuVMAgent -Name $n -Method input.act -Params @{ actions = @(@{ type = 'wait'; ms = 5000 }) * 12 } -TimeoutSec 120 } catch { $_.Exception.Message }
            [ordered]@{ ms = [math]::Round($w.Elapsed.TotalMilliseconds); result = $r }
        }
        Start-Sleep -Seconds 2
        $w = [Diagnostics.Stopwatch]::StartNew()
        # gpuvm-host is a windowless (GUI-subsystem) exe: PowerShell doesn't wait for it by itself.
        Start-Process $installedHost -ArgumentList 'install' -Wait -WindowStyle Hidden
        $installMs = [math]::Round($w.Elapsed.TotalMilliseconds)
        $state = (Get-Service GpuVM).Status
        $request = $job | Wait-Job -Timeout 90 | Receive-Job
        Start-Service GpuVM
        $result['boundedStop'] = [ordered]@{ installOverRunningServiceMs = $installMs; serviceAfterInstall = "$state"; longRequest = $request
            hostLog = @(Get-Content (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'GpuVM\host.log') -Tail 5) }
        Line "bounded stop: $($result['boundedStop'] | ConvertTo-Json -Compress -Depth 4)"
        Save
    }

    if ('mcp' -in $Steps) {
        # The MCP server's own path, through the installed gpuvm.exe --mcp and the service pipe: create_disposable
        # (New-GpuVM -Template -Disposable with the session's Connection, then Install-GpuVMAgent from the bridge,
        # an elevated user, not SYSTEM), take_machine, a screenshot, destroy. My copies go first (memory).
        Remove-Copies
        $exe = Join-Path $env:ProgramFiles 'GpuVM\gpuvm.exe'
        $drive = Join-Path $root 'labs\053-mcp\drive.py'
        $before = @(Get-VM | ForEach-Object Name)
        $text = & python $drive --exe $exe --template $Template --phases latency --rounds 3 2>&1
        # A disposable the MCP made in this step and didn't destroy (a failed run) goes too.
        foreach ($v in @(Get-VM | Where-Object { $_.Name -notin $before -and $_.Name -like "$Template-*" } | ForEach-Object Name)) { $made.Add($v) }
        $result['mcpPath'] = @($text | Select-Object -Last 25 | ForEach-Object { "$_" })
        $text | Select-Object -Last 25 | ForEach-Object { Line "mcp: $_" }
        $result['mcpRegistrations'] = @(Get-ChildItem (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'GpuVM\agents') -Directory |
            ForEach-Object { "$($_.Name): $(@(Get-ChildItem $_.FullName -Force | ForEach-Object Name) -join ',')" })
        Save
    }
}
finally {
    Remove-Copies
    if ($script:swapped) {
        # The installed service and module go back exactly as they were.
        try {
            Start-Process $boundedStop -ArgumentList 'stop' -Wait -WindowStyle Hidden
            Copy-Item (Join-Path $backupDir 'gpuvm-host.exe') $installedHost -Force
            Copy-Item (Join-Path $backupDir 'Agent.ps1') $installedAgentPs1 -Force
            Start-Service GpuVM
            Line 'installed gpuvm-host.exe and Agent.ps1 put back'
        }
        catch { Line "COULDN'T PUT BACK THE INSTALLED FILES: $($_.Exception.Message)" }
    }
    $result['finished'] = (Get-Date).ToString('o')
    Save
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Line 'lock released'
}
