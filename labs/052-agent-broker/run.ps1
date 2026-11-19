# Lab 052: the host agent broker end to end against a test VM running stub052 (the guest stand-in).
# Parts (pass as a list via -Command, never -File): install latency parallel timeout attacks offers restart
# broker-restart squat uninstall. Results: out/<part>-<time>.json. Run elevated, with the broker up (broker.ps1).
param(
    [string]$Name = 'agent052',
    [string[]]$Parts = @('install', 'latency', 'parallel', 'timeout', 'attacks', 'offers'),
    [int]$Rounds = 2,
    [string]$Session = 'agent-broker',
    # No VM: the stub runs on this PC over Hyper-V's loopback as the registered machine 'loopback052' (loopback.ps1).
    [switch]$Loopback,
    # The real guest agent instead of the stub: a checkout of the guest agent's branch (install.ps1 and the built
    # target\release\gpuvm-agent.exe are used from there; the stub only plays the attacker, copied into the guest).
    [string]$AgentFrom,
    # The real guest agent is installed in the VM (an installed GpuVM gives it): attacks use a copy of the stub.
    [switch]$Real,
    # Another GpuVM module (the installed one) instead of this checkout's.
    [string]$ModulePath
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null
Import-Module $(if ($ModulePath) { $ModulePath } else { Join-Path $root 'src\GpuVM\GpuVM.psd1' }) -Force
if ($AgentFrom) { $Real = $true }
. (Join-Path $root 'tools\latency\common.ps1')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stub = Join-Path $PSScriptRoot 'stub\target\release\stub052.exe'
$loopDir = 'C:\GpuVM\lab052\loopback'
$loopId = 'e0e16197-dd56-4a10-9195-5ee7a155a838'
if ($Loopback) {
    $Name = 'loopback052'
    $stamp = "loopback-$stamp"
    $cred = $null
    $env:STUB052_TARGET = 'loopback'
    $env:STUB052_OUTBOX = Join-Path $loopDir 'Outbox'
    New-Item -ItemType Directory -Force $env:STUB052_OUTBOX | Out-Null
    Get-Process stub052 -ErrorAction SilentlyContinue | Stop-Process -Force
    $stubProcess = Start-Process $stub -ArgumentList 'run', '--secret', "$loopDir\secret.raw", '--vm-id', $loopId, '--log', "$loopDir\stub.log" -PassThru -WindowStyle Hidden
}
else { $cred = (Get-LatencyVM -Name $Name).Guest }
$outboxDir = if ($Loopback) { $env:STUB052_OUTBOX } else { 'C:\Users\agent\Desktop\Outbox' }
# The real agent says where its home is (a profile folder can be named otherwise).
if ($Real) {
    $home052 = (Invoke-GpuVMAgent -Name $Name -Method agent.info).result.home
    if ($home052) { $outboxDir = Join-Path $home052 'Desktop\Outbox' }
}

# One hostile behaviour of the stub, in the guest (as an administrator, who can read the secret like SYSTEM) or here.
function Invoke-StubAttack([string]$case) {
    if ($Loopback) { return & $stub attack $case --secret "$loopDir\secret.raw" --vm-id $loopId }
    if ($Real) {
        if (-not $script:stubInGuest) {
            $s = New-PSSession -VMName $Name -Credential $cred
            Invoke-Command -Session $s { New-Item -ItemType Directory -Force 'C:\Windows\Temp\GpuVMLab052' | Out-Null }
            Copy-Item $stub -ToSession $s -Destination 'C:\Windows\Temp\GpuVMLab052\stub052.exe' -Force
            Remove-PSSession $s
            $script:stubInGuest = $true
        }
        return Invoke-Guest { param($c) & 'C:\Windows\Temp\GpuVMLab052\stub052.exe' attack $c --secret 'C:\ProgramData\GpuVM\Agent\secret' } @($case)
    }
    Invoke-Guest { param($c) & 'C:\ProgramData\GpuVM\Agent\stub052.exe' attack $c } @($case)
}
function Set-RealAgent([bool]$Running) {
    if ($Loopback) {
        if ($Running) {
            $script:stubProcess = Start-Process $stub -ArgumentList 'run', '--secret', "$loopDir\secret.raw", '--vm-id', $loopId, '--log', "$loopDir\stub.log" -PassThru -WindowStyle Hidden
        }
        else { Stop-Process -Id $script:stubProcess.Id -Force; Start-Sleep -Milliseconds 300 }
        return
    }
    if ($Real) {
        Invoke-Guest { param($on) if ($on) { Start-Service GpuVMAgent } else { Stop-Service GpuVMAgent -Force } } @($Running)
        Start-Sleep -Milliseconds 300
        return
    }
    Invoke-Guest {
        param($on)
        if ($on) { Start-ScheduledTask -TaskName GpuVMLab052-agent }
        else { Stop-ScheduledTask -TaskName GpuVMLab052-agent; Get-Process stub052 -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq 0 } | Stop-Process -Force }
    } @($Running)
    Start-Sleep -Milliseconds 300
}
function Get-AgentLog {
    if ($Loopback) { return Join-Path $loopDir 'agent.log' }
    Join-Path (Get-VM -Name $Name).Path 'agent.log'
}

function Save-Result([string]$part, $data) {
    $file = Join-Path $out "$part-$stamp.json"
    $data | ConvertTo-Json -Depth 8 | Set-Content $file -Encoding utf8
    "saved $file"
}

function Get-Stats([double[]]$v) {
    if (-not $v.Count) { return $null }
    $s = $v | Sort-Object
    $at = { param($p) $s[[math]::Min($s.Count - 1, [math]::Floor($p * $s.Count))] }
    [ordered]@{ n = $s.Count; mean = [math]::Round(($s | Measure-Object -Average).Average, 3); p50 = [math]::Round((& $at 0.5), 3)
        p95 = [math]::Round((& $at 0.95), 3); p99 = [math]::Round((& $at 0.99), 3); max = [math]::Round($s[-1], 3) }
}

# A raw client of the broker's module pipe: one JSON line out, one back, no cmdlet in between (the instrument).
function Open-Raw {
    $p = [IO.Pipes.NamedPipeClientStream]::new('.', 'gpuvm-agent', [IO.Pipes.PipeDirection]::InOut)
    $p.Connect(3000)
    [pscustomobject]@{ Pipe = $p; Reader = [IO.StreamReader]::new($p, [Text.UTF8Encoding]::new($false), $false, 1MB, $true)
        Writer = [IO.StreamWriter]::new($p, [Text.UTF8Encoding]::new($false), 65536, $true) }
}
function Send-Raw($raw, [string]$line) {
    $raw.Writer.Write($line + "`n"); $raw.Writer.Flush()
    $raw.Reader.ReadLine()
}
function Get-AgentState {
    $a = @(Get-GpuVMAgent -Name $Name)[0]
    $a
}
function Wait-AgentReady([double]$timeoutSec, [long]$after = 0) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $raw = Open-Raw
    try {
        while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
            $r = (Send-Raw $raw (@{ id = 1; cmd = 'Get-GpuVMAgent'; args = @{ Name = $Name } } | ConvertTo-Json -Compress)) | ConvertFrom-Json
            $a = $r.data[0]
            if ($a.state -eq 'ready' -and [long]$a.connectedSince -gt $after) { return $sw.Elapsed.TotalMilliseconds }
            Start-Sleep -Milliseconds 50
        }
    }
    finally { $raw.Pipe.Dispose() }
    $null
}
function Invoke-Guest([scriptblock]$Block, [object[]]$Arguments = @()) {
    if ($Loopback) { return & $Block @Arguments }
    Invoke-Command -VMName $Name -Credential $cred -ErrorAction Stop -ScriptBlock $Block -ArgumentList $Arguments
}

# ---------------------------------------------------------------- preflight
if (-not $Loopback -and (Get-VM -Name $Name).State -ne 'Running') { throw "$Name is off" }
$b = Get-GpuVMAgentBroker
if (-not $b.listening) { throw "the broker isn't listening: $($b.error)" }
"broker listening; parts: $($Parts -join ', ')"
if ($Loopback -and -not (Wait-AgentReady 10)) { throw 'the loopback stub did not connect' }

try {
foreach ($part in $Parts) {
    "== $part"
    switch ($part) {
        'install' {
            # The real guest agent from its branch's checkout plays guest\agent\{install.ps1,dist} while it isn't
            # merged here; removed again at the end (only what the lab created).
            $agentDir = Join-Path $root 'guest\agent'
            $created = -not (Test-Path (Join-Path $agentDir 'install.ps1'))
            if ($created) {
                if (-not $AgentFrom) { throw 'install needs -AgentFrom (the guest agent checkout)' }
                New-Item -ItemType Directory -Force (Join-Path $agentDir 'dist') | Out-Null
                Copy-Item (Join-Path $AgentFrom 'guest\agent\install.ps1') (Join-Path $agentDir 'install.ps1')
                Copy-Item (Join-Path $AgentFrom 'guest\agent\dist\*') (Join-Path $agentDir 'dist')
            }
            try {
                $gsiBefore = (Get-VMIntegrationService -VMName $Name | Where-Object { $_.Id -like '*6C09BB55-D683-4DA0-8931-C9BF705F6480' }).Enabled
                $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $r = Install-GpuVMAgent -Name $Name
                $installMs = $sw.Elapsed.TotalMilliseconds
                $readyMs = Wait-AgentReady 240 $t0
                # Again: the same build is already there (what a copy of a template gets).
                $t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                $sw.Restart()
                $r2 = Install-GpuVMAgent -Name $Name
                $again = [ordered]@{ ms = $r2.ms; fastPath = $r2.fastPath; restarted = $r2.restarted; totalMs = [math]::Round($sw.Elapsed.TotalMilliseconds)
                    readyMs = Wait-AgentReady 240 $t1 }
                $gsiAfter = (Get-VMIntegrationService -VMName $Name | Where-Object { $_.Id -like '*6C09BB55-D683-4DA0-8931-C9BF705F6480' }).Enabled
                $secretFile = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "GpuVM\agents\$($r.vmId)\secret"
                $adminCanRead = try { [IO.File]::ReadAllBytes($secretFile) | Out-Null; $true } catch { $false }
                $guest = Invoke-Guest {
                    $acl = Get-Acl 'C:\ProgramData\GpuVM\Agent\secret'
                    [pscustomobject]@{ size = (Get-Item 'C:\ProgramData\GpuVM\Agent\secret').Length; owner = $acl.Owner
                        sids = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique)
                        kvp = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\External' -ErrorAction SilentlyContinue).Count }
                }
                $agent = Get-AgentState
                $result = [ordered]@{ install = $r; installMs = [math]::Round($installMs); readyAfterInstallMs = $readyMs; again = $again
                    gsiBefore = $gsiBefore; gsiAfter = $gsiAfter
                    hostSecretReadableByAdmin = $adminCanRead; guestSecret = $guest; agent = $agent }
                $result | ConvertTo-Json -Depth 5 -Compress
                Save-Result 'install' $result
            }
            finally {
                if ($created) { Remove-Item (Join-Path $agentDir 'install.ps1'), (Join-Path $agentDir 'dist') -Recurse -Force }
            }
        }
        'latency' {
            # End to end through the broker's module pipe: raw line (instrument), the cmdlet, and blob sizes.
            $raw = Open-Raw
            $samples = @{}
            $cases = if ($Real) {
                [ordered]@{
                    'agent.info raw'          = @{ Method = 'agent.info'; Params = @{} }
                    'screen.state'            = @{ Method = 'screen.state'; Params = @{} }
                    'screen.capture 1280x800' = @{ Method = 'screen.capture'; Params = @{ maxW = 1280; maxH = 800 } }
                    'input.act move'          = @{ Method = 'input.act'; Params = @{ actions = @(@{ type = 'move'; x = 400; y = 300 }) } }
                    'ui.tree'                 = @{ Method = 'ui.tree'; Params = @{} }
                }
            } else { [ordered]@{
                'agent.info raw'         = @{ Method = 'agent.info'; Params = @{} }
                'screen.capture 257KB'   = @{ Method = 'screen.capture'; Params = @{ bytes = 257000 } }
                'screen.capture 1MB'     = @{ Method = 'screen.capture'; Params = @{ bytes = 1MB } }
                'screen.capture 4MB'     = @{ Method = 'screen.capture'; Params = @{ bytes = 4MB } }
            } }
            foreach ($k in @($cases.Keys) + 'agent.info cmdlet' + 'agent.info broker-ms') { $samples[$k] = [System.Collections.Generic.List[double]]::new() }
            for ($round = 0; $round -lt $Rounds; $round++) {
                for ($i = 0; $i -lt 60; $i++) {
                    foreach ($k in $cases.Keys) {
                        $c = $cases[$k]
                        $line = @{ id = $i; cmd = 'Invoke-GpuVMAgent'; args = @{ Name = $Name; Method = $c.Method; Params = $c.Params } } | ConvertTo-Json -Compress -Depth 5
                        $sw = [Diagnostics.Stopwatch]::StartNew()
                        $reply = Send-Raw $raw $line
                        $ms = $sw.Elapsed.TotalMilliseconds
                        $d = ($reply | ConvertFrom-Json).data[0]
                        if (-not $d.ok) { throw "request failed: $reply" }
                        $samples[$k].Add($ms)
                        if ($k -eq 'agent.info raw') { $samples['agent.info broker-ms'].Add([double]$d.ms) }
                        if ($d.blobPath) { Remove-Item $d.blobPath -Force }
                        Start-Sleep -Milliseconds (Get-Random -Minimum 2 -Maximum 20)
                    }
                    $sw = [Diagnostics.Stopwatch]::StartNew()
                    $null = Invoke-GpuVMAgent -Name $Name -Method agent.info
                    $samples['agent.info cmdlet'].Add($sw.Elapsed.TotalMilliseconds)
                }
            }
            $raw.Pipe.Dispose()
            # Instrument reference: the same pipe and broker without the guest (an unknown machine answers at once).
            $raw = Open-Raw
            $ref = [System.Collections.Generic.List[double]]::new()
            for ($i = 0; $i -lt 200; $i++) {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $null = Send-Raw $raw '{"id":1,"cmd":"Get-GpuVMAgentBroker","args":{}}'
                $ref.Add($sw.Elapsed.TotalMilliseconds)
            }
            $raw.Pipe.Dispose()
            $result = [ordered]@{ reference_pipe_only = Get-Stats $ref }
            foreach ($k in $samples.Keys) { $result[$k] = Get-Stats $samples[$k] }
            $result | ConvertTo-Json -Compress
            Save-Result 'latency' $result
        }
        'parallel' {
            # 8 clients at once, each with its own pipe connection, 150 agent.info + 20 captures of 257 KB each.
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $all = 1..8 | ForEach-Object -ThrottleLimit 8 -Parallel {
                $vm = $using:Name
                $p = [IO.Pipes.NamedPipeClientStream]::new('.', 'gpuvm-agent', [IO.Pipes.PipeDirection]::InOut); $p.Connect(3000)
                $r = [IO.StreamReader]::new($p, [Text.UTF8Encoding]::new($false), $false, 1MB, $true)
                $w = [IO.StreamWriter]::new($p, [Text.UTF8Encoding]::new($false), 65536, $true)
                $times = [System.Collections.Generic.List[double]]::new(); $fails = 0
                for ($i = 0; $i -lt 170; $i++) {
                    $m = if ($i % 9 -eq 0) { @{ Method = 'screen.capture'; Params = @{ bytes = 257000 } } } else { @{ Method = 'agent.info'; Params = @{} } }
                    $line = @{ id = $i; cmd = 'Invoke-GpuVMAgent'; args = @{ Name = $vm; Method = $m.Method; Params = $m.Params } } | ConvertTo-Json -Compress -Depth 5
                    $t = [Diagnostics.Stopwatch]::StartNew()
                    $w.Write($line + "`n"); $w.Flush()
                    $d = ($r.ReadLine() | ConvertFrom-Json).data[0]
                    $times.Add($t.Elapsed.TotalMilliseconds)
                    if (-not $d.ok) { $fails++ }
                    if ($d.blobPath) { Remove-Item $d.blobPath -Force }
                }
                $p.Dispose()
                [pscustomobject]@{ times = $times.ToArray(); fails = $fails }
            }
            $wall = $sw.Elapsed.TotalMilliseconds
            $times = @($all | ForEach-Object { $_.times }) | ForEach-Object { [double]$_ }
            $result = [ordered]@{ clients = 8; requests = $times.Count; failed = ($all | Measure-Object fails -Sum).Sum
                wallMs = [math]::Round($wall); perSecond = [math]::Round($times.Count / ($wall / 1000)); latency = Get-Stats $times }
            $result | ConvertTo-Json -Compress
            Save-Result 'parallel' $result
        }
        'timeout' {
            # A request the guest holds for 5 s with a 1 s timeout: the caller gets "timeout" at ~1 s, the guest gets a
            # cancel, and the next request works at once. Then 40 requests in flight (the cap is 32).
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-GpuVMAgent -Name $Name -Method input.act -Params @{ actions = @(@{ type = 'wait'; ms = 5000 }) } -TimeoutSec 1
            $timeoutMs = $sw.Elapsed.TotalMilliseconds
            $sw.Restart()
            $next = Invoke-GpuVMAgent -Name $Name -Method agent.info
            $nextMs = $sw.Elapsed.TotalMilliseconds
            $burst = 1..40 | ForEach-Object -ThrottleLimit 40 -Parallel {
                $p = [IO.Pipes.NamedPipeClientStream]::new('.', 'gpuvm-agent', [IO.Pipes.PipeDirection]::InOut); $p.Connect(3000)
                $r = [IO.StreamReader]::new($p); $w = [IO.StreamWriter]::new($p)
                $w.Write((@{ id = 1; cmd = 'Invoke-GpuVMAgent'; args = @{ Name = $using:Name; Method = 'input.act'; Params = @{ actions = @(@{ type = 'wait'; ms = 2000 }) }; TimeoutSec = 10 } } | ConvertTo-Json -Compress -Depth 6) + "`n"); $w.Flush()
                $d = ($r.ReadLine() | ConvertFrom-Json).data[0]
                $p.Dispose()
                if ($d.ok) { 'ok' } else { $d.error.code }
            }
            $result = [ordered]@{ timeout = [ordered]@{ code = $r.error.code; ms = [math]::Round($timeoutMs) }; nextOk = $next.ok; nextMs = [math]::Round($nextMs, 2)
                burst40 = ($burst | Group-Object | ForEach-Object { @{ $_.Name = $_.Count } }) }
            $result | ConvertTo-Json -Compress -Depth 4
            Save-Result 'timeout' $result
        }
        'attacks' {
            # Each hostile behaviour runs in the guest as an administrator (who can read the secret, like SYSTEM).
            # After each one: the real agent must still be (or get back to) connected and the broker must answer.
            $cases = 'wrong-secret', 'wrong-vm', 'replay', 'big-hello', 'bad-kind', 'garbage-hello', 'slow-hello', 'big-json', 'big-blob',
                'unsigned', 'malformed', 'stray-res', 'stray-blob', 'bad-blob-hash', 'silent', 'frame-flood', 'event-flood', 'conn-flood', 'good'
            $rows = foreach ($case in $cases) {
                $before = Get-AgentState
                # These two need the attacker's connection to stay the newest one: the real agent pauses meanwhile
                # (it would redial and replace it within 200 ms).
                $pause = $case -in 'silent', 'event-flood'
                if ($pause) { Set-RealAgent -Running $false }
                try {
                    $line = Invoke-StubAttack $case
                }
                finally { if ($pause) { Set-RealAgent -Running $true } }
                $res = $line | ConvertFrom-Json
                $back = Wait-AgentReady 20
                $after = Get-AgentState
                $row = [ordered]@{ case = $case; result = $res; agentReadyAfterMs = $back
                    agentKeptConnection = ($before.connectedSince -eq $after.connectedSince); brokerOk = [bool](Get-GpuVMAgentBroker).listening }
                Write-Host ($row | ConvertTo-Json -Compress -Depth 4)
                $row
                Start-Sleep -Milliseconds 500
            }
            $log = Get-AgentLog
            Save-Result 'attacks' ([ordered]@{ rows = @($rows); logTail = @(Get-Content $log -Tail 80) })
        }
        'offers' {
            # Files leave only from Desktop\Outbox, after approval, as the person, never overwriting, marked as from the
            # internet; a 20 MB file crosses in 8 MB pieces.
            $sha = Invoke-Guest {
                param($o)
                New-Item -ItemType Directory -Force $o | Out-Null
                Set-Content "$o\report.txt" "lab 052 report $(Get-Date -Format o)" -Encoding utf8
                $b = [byte[]]::new(20MB); [Random]::new(52).NextBytes($b); [IO.File]::WriteAllBytes("$o\big.bin", $b)
                @{ report = (Get-FileHash "$o\report.txt").Hash; big = (Get-FileHash "$o\big.bin").Hash }
            } @($outboxDir)
            $dest = Join-Path ([Environment]::GetFolderPath('UserProfile')) "Downloads\GpuVM\$Name"
            $preexisting = @(if (Test-Path $dest) { Get-ChildItem $dest -File | ForEach-Object FullName })
            $made = [System.Collections.Generic.List[string]]::new()
            $rows = [ordered]@{}
            try {
                foreach ($f in 'report.txt', 'report.txt', 'big.bin') {
                    $o = New-GpuVMAgentOffer -Name $Name -Path "Desktop\Outbox\$f" -Note 'lab 052'
                    $pending = Get-GpuVMAgentOffer -Id $o.offerId
                    $sw = [Diagnostics.Stopwatch]::StartNew()
                    $done = Resolve-GpuVMAgentOffer -Id $o.offerId -Accept $true
                    $ms = $sw.Elapsed.TotalMilliseconds
                    $made.Add($done.hostPath)
                    $zone = Get-Content -Raw -LiteralPath $done.hostPath -Stream Zone.Identifier
                    $rows["$f#$($made.Count)"] = [ordered]@{ sizeShown = $pending.size; state = $done.state; hostPath = $done.hostPath; ms = [math]::Round($ms)
                        sameBytes = ((Get-FileHash $done.hostPath).Hash -eq $sha[$f.Split('.')[0]]); zone = $zone.Trim()
                        owner = (Get-Acl $done.hostPath).Owner }
                }
                $declined = New-GpuVMAgentOffer -Name $Name -Path 'Desktop\Outbox\report.txt'
                $rows['decline'] = (Resolve-GpuVMAgentOffer -Id $declined.offerId -Accept $false).state
                $rows['answer twice'] = try { Resolve-GpuVMAgentOffer -Id $declined.offerId -Accept $true; 'accepted!' } catch { $_.Exception.Message }
                foreach ($bad in 'C:\Users\agent\secret.txt', 'C:\Users\agent\Desktop\Outbox\..\..\secret.txt', 'C:\Users\agent\Desktop\Outbox\sub\x.txt', 'C:\Windows\win.ini') {
                    $rows["refused $bad"] = try { New-GpuVMAgentOffer -Name $Name -Path $bad | Out-Null; 'ACCEPTED' } catch { "$($_.Exception.Data['code']): $($_.Exception.Message)" }
                }
            }
            finally {
                # Only the files this lab made in the person's Downloads are removed.
                foreach ($p in $made) { if ($p -and $p -notin $preexisting) { Remove-Item -LiteralPath $p -Force } }
                if ((Test-Path $dest) -and -not (Get-ChildItem $dest -Force)) { Remove-Item $dest }
            }
            $rows | ConvertTo-Json -Compress -Depth 4
            Save-Result 'offers' $rows
        }
        'restart' {
            # Guest restart: how long until the agent is connected again, and PowerShell Direct for comparison.
            $rows = for ($i = 0; $i -lt $Rounds; $i++) {
                $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                $sw = [Diagnostics.Stopwatch]::StartNew()
                Invoke-Guest { Restart-Computer -Force }
                $dropMs = $null
                while ($sw.Elapsed.TotalSeconds -lt 60) { if ((Get-AgentState).state -ne 'ready') { $dropMs = $sw.Elapsed.TotalMilliseconds; break }; Start-Sleep -Milliseconds 50 }
                $ready = Wait-AgentReady 180 $t0
                $agentMs = $sw.Elapsed.TotalMilliseconds
                $psd = $null
                while ($sw.Elapsed.TotalSeconds -lt 300) { try { Invoke-Guest { 1 } | Out-Null; $psd = $sw.Elapsed.TotalMilliseconds; break } catch { Start-Sleep -Milliseconds 250 } }
                $row = [ordered]@{ hostNoticedDropMs = $dropMs; agentReadyMs = if ($ready) { [math]::Round($agentMs) }; psDirectMs = $psd }
                Write-Host ($row | ConvertTo-Json -Compress)
                $row
            }
            Save-Result 'restart' @($rows)
        }
        'broker-restart' {
            # The service restarts (update, crash): the agents come back by themselves.
            $rows = for ($i = 0; $i -lt $Rounds; $i++) {
                & (Join-Path $PSScriptRoot 'broker.ps1') -Stop | Out-Null
                $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                $sw = [Diagnostics.Stopwatch]::StartNew()
                & (Join-Path $PSScriptRoot 'broker.ps1') | Out-Null
                $up = $sw.Elapsed.TotalMilliseconds
                $ready = Wait-AgentReady 30 $t0
                $row = [ordered]@{ brokerUpMs = [math]::Round($up); agentReadyMs = if ($ready) { [math]::Round($sw.Elapsed.TotalMilliseconds) } }
                Write-Host ($row | ConvertTo-Json -Compress)
                $row
            }
            Save-Result 'broker-restart' @($rows)
        }
        'squat' {
            # Another program takes the channel's name before the broker: the broker says so, and the guest agent
            # refuses the impostor (it can't prove it knows the secret).
            $hvlab = Join-Path $root 'labs\047-hvsocket\hvlab\target\release\hvlab.exe'
            if (-not (Test-Path $hvlab)) { & cargo build --release --manifest-path (Join-Path $root 'labs\047-hvsocket\hvlab\Cargo.toml') 2>&1 | Select-Object -Last 1 }
            & (Join-Path $PSScriptRoot 'broker.ps1') -Stop | Out-Null
            $squatter = Start-Process $hvlab -ArgumentList 'listen', '--bind', 'children', '--service', '94aca5ef-a5b6-45a9-8c15-c7724a63f3da' -PassThru -WindowStyle Hidden
            try {
                Start-Sleep -Seconds 3
                & (Join-Path $PSScriptRoot 'broker.ps1') | Out-Null
                Start-Sleep -Seconds 2
                $status = Get-GpuVMAgentBroker
                $stubLog = Invoke-Guest { Get-Content 'C:\ProgramData\GpuVM\Agent\stub.log' -Tail 5 }
            }
            finally { Stop-Process -Id $squatter.Id -Force -ErrorAction SilentlyContinue }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $listening = $null
            while ($sw.Elapsed.TotalSeconds -lt 15) { if ((Get-GpuVMAgentBroker).listening) { $listening = $sw.Elapsed.TotalMilliseconds; break }; Start-Sleep -Milliseconds 100 }
            $ready = Wait-AgentReady 20
            $result = [ordered]@{ whileSquatted = $status; guestStubLog = @($stubLog); brokerListeningAfterSquatterLeftMs = $listening; agentReadyAfterMs = $ready }
            $result | ConvertTo-Json -Compress -Depth 4
            Save-Result 'squat' $result
        }
        'two' {
            # Two machines at once: the VM over VMBus and the loopback stub, 4 clients each, every answer checked
            # against the machine it was asked (agent.info returns the stub's VmId).
            $env:STUB052_TARGET = 'loopback'
            $loop = Start-Process $stub -ArgumentList 'run', '--secret', "$loopDir\secret.raw", '--vm-id', $loopId -PassThru -WindowStyle Hidden
            Remove-Item Env:\STUB052_TARGET
            try {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                while ((@(Get-GpuVMAgent -Name loopback052)[0]).state -ne 'ready' -and $sw.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 100 }
                $expected = @{ $Name = (Get-VM -Name $Name).Id.Guid.ToLowerInvariant(); loopback052 = $loopId }
                $both = @(Get-GpuVMAgent | Where-Object state -eq 'ready').name
                $sw.Restart()
                $runs = foreach ($m in $Name, 'loopback052') { foreach ($k in 1..4) { [pscustomobject]@{ Machine = $m; Want = $expected[$m] } } }
                $all = $runs | ForEach-Object -ThrottleLimit 8 -Parallel {
                    $p = [IO.Pipes.NamedPipeClientStream]::new('.', 'gpuvm-agent', [IO.Pipes.PipeDirection]::InOut); $p.Connect(3000)
                    $r = [IO.StreamReader]::new($p); $w = [IO.StreamWriter]::new($p)
                    $times = [System.Collections.Generic.List[double]]::new(); $wrong = 0; $fails = 0
                    for ($i = 0; $i -lt 200; $i++) {
                        $t = [Diagnostics.Stopwatch]::StartNew()
                        $w.Write((@{ id = $i; cmd = 'Invoke-GpuVMAgent'; args = @{ Name = $_.Machine; Method = 'agent.info' } } | ConvertTo-Json -Compress) + "`n"); $w.Flush()
                        $d = ($r.ReadLine() | ConvertFrom-Json).data[0]
                        $times.Add($t.Elapsed.TotalMilliseconds)
                        if (-not $d.ok) { $fails++ } elseif ($d.result.vmId -ne $_.Want) { $wrong++ }
                    }
                    $p.Dispose()
                    [pscustomobject]@{ machine = $_.Machine; times = $times.ToArray(); wrong = $wrong; fails = $fails }
                }
                $wall = $sw.Elapsed.TotalMilliseconds
                $result = [ordered]@{ readyAtOnce = $both; wallMs = [math]::Round($wall) }
                foreach ($g in $all | Group-Object machine) {
                    $result[$g.Name] = [ordered]@{ requests = ($g.Group.times | Measure-Object).Count; wrongMachine = ($g.Group | Measure-Object wrong -Sum).Sum
                        failed = ($g.Group | Measure-Object fails -Sum).Sum; latency = Get-Stats ([double[]]@($g.Group.times)) }
                }
                $result | ConvertTo-Json -Compress -Depth 4
                Save-Result 'two' $result
            }
            finally { Stop-Process -Id $loop.Id -Force -ErrorAction SilentlyContinue }
        }
        'uninstall' {
            $vmId = (Get-VM -Name $Name).Id.Guid
            Uninstall-GpuVMAgent -Name $Name | Out-Null
            Start-Sleep -Seconds 3
            $result = [ordered]@{ state = (Get-AgentState).state; registrationGone = -not (Test-Path (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "GpuVM\agents\$vmId")) }
            $result | ConvertTo-Json -Compress
            Save-Result 'uninstall' $result
        }
        default { throw "unknown part $part" }
    }
}
}
finally {
    if ($Loopback -and $stubProcess) { Stop-Process -Id $stubProcess.Id -Force -ErrorAction SilentlyContinue }
}
