# Lab 068: GpuVM's agent as the admin channel of an HCS machine. The agent is installed into the stopped machine's
# disk (program, protected secret and machine id, offline service), the machine starts, the agent dials this branch's
# host broker, and sys.info / sys.exec / sys.write / sys.read / sys.power replace PowerShell Direct, KVP and the
# Hyper-V heartbeat. The installed GpuVM service is stopped for the run (the broker needs the agent channel) and
# started again at the end if it was running.
#   pwsh -NoProfile -File labs/068-hcs-guest-channel/run.ps1
# Needs an elevated shell and a debug build of app/host (the broker command only exists there). Takes the lab lock.
param([string]$Template = 'normal-tpl', [int]$TimeoutSec = 300,
    [string]$Exe = (Join-Path $PSScriptRoot '..\..\app\host\target\debug\gpuvm-host.exe'),
    [string]$Agent = (Join-Path $PSScriptRoot '..\..\app\guest-agent-target\release\gpuvm-agent.exe'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = $PSScriptRoot
$root = 'C:\GpuVM\.lab068'; $name = 'm068'; $lock = 'C:\GpuVM\.lab-lock'; $task = 'GpuVMLab068Broker'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $here 'out'; $null = New-Item -ItemType Directory -Force $outDir
$res = [ordered]@{ runId = $runId; steps = [ordered]@{} }
$sw = [Diagnostics.Stopwatch]::StartNew()
function Log([string]$m) { Write-Host ("[{0,6:n1}s] {1}" -f $sw.Elapsed.TotalSeconds, $m) }
function Hcs([string[]]$Arguments, [switch]$Soft) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    $o = (& $Exe hcs @Arguments | Select-Object -Last 1) | ConvertFrom-Json
    $key = "$($Arguments[0])$(if ($Arguments[0] -eq 'ask') { '-' + $Arguments[2] })-$($res.steps.Count)"
    $res.steps[$key] = [ordered]@{ ms = [math]::Round($t.Elapsed.TotalMilliseconds); out = $o }
    if (-not $o.ok -and -not $Soft) { throw "hcs $($Arguments[0]): $($o.error)" }
    $o
}
function Ask([string]$Method, [string]$Params = '{}', [string[]]$More = @()) {
    $o = Hcs (@('ask', $name, $Method, $Params) + $More) -Soft
    if (-not $o.ok) { throw "ask ${Method}: $($o.error)" }
    if (-not $o.result.ok) { throw "ask ${Method}: $($o.result.error.code) $($o.result.error.message)" }
    Log "$Method ok ($($res.steps[@($res.steps.Keys)[-1]].ms) ms)"
    $o.result.result
}
function Send-AdminPipe($Request) {
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'gpuvm-agent', [IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(3000)
    $w = [IO.StreamWriter]::new($pipe); $w.AutoFlush = $true; $r = [IO.StreamReader]::new($pipe)
    $w.WriteLine(($Request | ConvertTo-Json -Compress -Depth 6))
    $line = $r.ReadLine(); $pipe.Dispose(); $line | ConvertFrom-Json
}

foreach ($f in $Exe, $Agent) { if (-not (Test-Path $f)) { throw "Missing $f (build app/host in debug and guest/agent in release)" } }
$Exe = (Resolve-Path $Exe).Path; $Agent = (Resolve-Path $Agent).Path
$tplDir = "C:\GpuVM\.templates\$Template"
$layer = Join-Path $tplDir ((Get-Content (Join-Path $tplDir 'template.json') -Raw | ConvertFrom-Json).layers[-1])

try { $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) }
catch [IO.IOException] { throw "The lab lock is held: $(Get-Content $lock -Raw)" }
$fs.Write([Text.Encoding]::UTF8.GetBytes("lab068 pid=$PID $(Get-Date -Format o)")); $fs.Close()
$service = Get-Service GpuVM -ErrorAction SilentlyContinue
$wasRunning = $service -and $service.Status -eq 'Running'
$scratch = Join-Path $env:TEMP "lab068-$PID"; $null = New-Item -ItemType Directory -Force $scratch
try {
    if ($wasRunning) { Stop-Service GpuVM -Force; Log 'installed GpuVM service stopped for the run' }
    & schtasks.exe /create /tn $task /tr "`"$Exe`" broker" /sc once /st 00:00 /ru SYSTEM /rl HIGHEST /f | Out-Null
    & schtasks.exe /run /tn $task | Out-Null
    $t = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path '\\.\pipe\gpuvm-agent')) { if ($t.Elapsed.TotalSeconds -gt 20) { throw 'the broker did not open its pipe' }; Start-Sleep -Milliseconds 300 }
    Log "broker up as SYSTEM ($([math]::Round($t.Elapsed.TotalSeconds,1)) s)"

    $null = Hcs @('create', $root, $name, $layer, '4096', '4', '--gpu', 'nvidia')
    $install = Hcs @('install-agent', $root, $name, $Agent)
    $res.install = $install.result
    Log "agent installed offline: vmId $($install.result.vmId) ($($install.result.ms) ms)"
    $start = Hcs @('start', $root, $name)
    $res.start = $start.result
    Log "started ($($start.result.ms) ms), runtimeId $($start.result.runtimeId)"
    $res.vmIdMatches = ($start.result.runtimeId -eq $install.result.vmId)

    $t = [Diagnostics.Stopwatch]::StartNew(); $info = $null
    while (-not $info) {
        $o = Hcs @('ask', $name, 'sys.info') -Soft
        if ($o.ok -and $o.result.ok) { $info = $o.result.result; break }
        if ($t.Elapsed.TotalSeconds -gt $TimeoutSec) { throw "the agent never answered: $(if ($o.ok) { $o.result.error.message } else { $o.error })" }
        Start-Sleep 2
    }
    $res.agentReadySec = [math]::Round($t.Elapsed.TotalSeconds, 1)
    $res.info = $info
    Log "agent answered sys.info $($res.agentReadySec) s after start: user $($info.user), ip $($info.ipv4 -join ',')"
    $t = [Diagnostics.Stopwatch]::StartNew()
    while (-not $info.setupDone -and $t.Elapsed.TotalSeconds -lt $TimeoutSec) { Start-Sleep 3; $info = Ask 'sys.info' }
    $res.setupDoneSec = if ($info.setupDone) { [math]::Round($t.Elapsed.TotalSeconds, 1) } else { -1 }

    $res.whoami = (Ask 'sys.exec' '{"file":"whoami.exe"}').stdout.Trim()
    $res.ver = (Ask 'sys.exec' '{"file":"cmd.exe","args":["/c","ver"]}').stdout.Trim()
    $gpu = Ask 'sys.exec' '{"file":"C:\\Windows\\System32\\nvidia-smi.exe","args":["--query-gpu=name,memory.total","--format=csv,noheader"]}'
    $res.nvidiaSmi = $gpu.stdout.Trim()
    $payload = Join-Path $scratch 'payload.bin'
    $bytes = [byte[]]::new(3MB); [Security.Cryptography.RandomNumberGenerator]::Fill($bytes); [IO.File]::WriteAllBytes($payload, $bytes)
    $null = Ask 'sys.write' '{"path":"C:\\GpuVMLab068\\payload.bin"}' @('--blob', $payload)
    $back = Join-Path $scratch 'back.bin'
    $null = Ask 'sys.read' '{"path":"C:\\GpuVMLab068\\payload.bin"}' @('--out', $back)
    $res.roundTripEqual = (Get-FileHash $payload).Hash -eq (Get-FileHash $back).Hash
    Log "3 MiB write + read back equal: $($res.roundTripEqual)"

    $denied = Send-AdminPipe @{ id = 2; cmd = 'Invoke-GpuVMAgent'; args = @{ Name = $name; Method = 'sys.info'; Connection = 'someone' } }
    $res.deniedWithConnection = $denied | ConvertTo-Json -Compress -Depth 5
    $unknown = Send-AdminPipe @{ id = 3; cmd = 'Invoke-GpuVMAgent'; args = @{ Name = $name; Method = 'sys.nope' } }
    $res.unknownMethod = $unknown | ConvertTo-Json -Compress -Depth 5

    $null = Ask 'sys.power' '{"action":"shutdown"}'
    $t = [Diagnostics.Stopwatch]::StartNew()
    while ((Hcs @('state', $root, $name)).result.state -ne 'Off') {
        if ($t.Elapsed.TotalSeconds -gt 120) { throw 'the machine did not turn off after sys.power' }
        Start-Sleep 2
    }
    $res.shutdownSec = [math]::Round($t.Elapsed.TotalSeconds, 1)
    Log "machine off $($res.shutdownSec) s after sys.power shutdown"
} catch { $res.error = "$_"; Log "FAILED: $_" }
finally {
    try { if (Test-Path (Join-Path $root "$name\hcs-machine.json")) { $null = Hcs @('off', $root, $name) -Soft; $null = Hcs @('delete', $root, $name) -Soft } } catch { $res.cleanupError = "$_" }
    try { $null = Hcs @('network-delete') -Soft } catch {}
    & schtasks.exe /end /tn $task 2>$null | Out-Null
    Get-CimInstance Win32_Process -Filter "Name='gpuvm-host.exe'" | Where-Object ExecutablePath -eq $Exe | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    & schtasks.exe /delete /tn $task /f 2>$null | Out-Null
    if ($wasRunning) { Start-Service GpuVM; Log 'installed GpuVM service started again' }
    Remove-Item $root, $scratch -Recurse -Force -ErrorAction SilentlyContinue
    $res.totalSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $res | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $outDir "$runId.json")
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
    Log "done -> out/$runId.json; left behind: root=$(Test-Path $root) lock=$(Test-Path $lock) service=$((Get-Service GpuVM -ErrorAction SilentlyContinue).Status)"
}
