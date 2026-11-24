# Lab 074: the isolated network of HCS machines as GpuVM ships it (lab 073 was the prototype). Nothing is set up by
# hand: `hcs start` puts an isolated machine on GpuVM-Isolated with a fixed address and the host's filters, and the
# service tells the agent (sys.net) as soon as it connects; the agent sets the address and runs the relay through
# its Wintun adapter. Arms: isolated, isolated after a guest restart, and not isolated (ICS) as the control.
#   pwsh -NoProfile -File labs/074-hcs-isolated-network/run.ps1
param([string]$Template = 'normal-tpl',
    [string]$Exe = (Join-Path $PSScriptRoot '..\..\app\host\target\debug\gpuvm-host.exe'),
    [string]$Agent = (Join-Path $PSScriptRoot '..\..\guest\agent\dist\gpuvm-agent.exe'),
    [int]$DownloadMB = 50)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = $PSScriptRoot
$root = 'C:\GpuVM\.lab074'; $name = 'm074'; $lock = 'C:\GpuVM\.lab-lock'; $task = 'GpuVMLab074Broker'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $here 'out'; $null = New-Item -ItemType Directory -Force $outDir
$res = [ordered]@{ runId = $runId; arms = [ordered]@{} }
$sw = [Diagnostics.Stopwatch]::StartNew()
function Write-Log([string]$m) { Write-Host ("[{0,6:n1}s] {1}" -f $sw.Elapsed.TotalSeconds, $m) }
function Invoke-Hc([string[]]$A) { $o = (& $Exe hcs @A | Select-Object -Last 1) | ConvertFrom-Json; if (-not $o.ok) { throw "hcs $($A[0]): $($o.error)" }; $o.result }
function Invoke-Ask([string]$Method, [string]$Params = '{}') {
    $o = (& $Exe hcs ask $name $Method $Params | Select-Object -Last 1) | ConvertFrom-Json
    if (-not $o.ok -or -not $o.result.ok) { return $null }
    $o.result.result
}
function Invoke-GuestPs([string]$Script, [int]$TimeoutMs = 30000) {
    $r = Invoke-Ask 'sys.exec' (@{ file = 'WindowsPowerShell\v1.0\powershell.exe'; args = @('-NoProfile', '-Command', $Script); timeoutMs = $TimeoutMs } | ConvertTo-Json -Compress)
    if ($r) { "$($r.stdout)".Trim() } else { 'no answer' }
}
# Connect result and how long it took: a refused flow should fail at once, not hang.
function Test-GuestTcp([string]$Target, [int]$Port) {
    Invoke-GuestPs ("`$w = [Diagnostics.Stopwatch]::StartNew(); `$c = [Net.Sockets.TcpClient]::new(); " +
        "`$r = try { if (`$c.ConnectAsync('$Target', $Port).Wait(5000) -and `$c.Connected) { 'open' } else { 'timeout' } } catch { 'refused' }; " +
        "`$r + ' ' + [math]::Round(`$w.Elapsed.TotalMilliseconds)")
}
function Test-GuestData([string]$Target, [int]$Port) {
    Invoke-GuestPs "curl.exe -s -o NUL -m 5 -w '%{http_code}' http://${Target}:$Port/; ' exit=' + `$LASTEXITCODE"
}
function Wait-Agent {
    $t = [Diagnostics.Stopwatch]::StartNew()
    while ($t.Elapsed.TotalSeconds -lt 240) { if (Invoke-Ask 'sys.info') { return [math]::Round($t.Elapsed.TotalSeconds, 1) }; Start-Sleep 2 }
    throw 'no agent'
}
function Wait-Internet {
    $t = [Diagnostics.Stopwatch]::StartNew()
    while ($t.Elapsed.TotalSeconds -lt 120) {
        if ((Invoke-GuestPs "curl.exe -s -o NUL -m 5 -w '%{http_code}' https://www.microsoft.com/") -eq '200') { return [math]::Round($t.Elapsed.TotalSeconds, 1) }
        Start-Sleep 2
    }
    'never'
}
function Measure-Guest([string]$GuestIp, [string]$HostIp) {
    $s = [Diagnostics.Stopwatch]::StartNew(); $up = $false
    while (-not $up -and $s.Elapsed.TotalSeconds -lt 90) {
        $up = try { $c = [Net.Sockets.TcpClient]::new(); [bool]($c.ConnectAsync($GuestIp, 47989).Wait(2000) -and $c.Connected) } catch { $false }
        if (-not $up) { Start-Sleep 2 }
    }
    $bytes = $DownloadMB * 1000000
    [ordered]@{
        internetByName = Test-GuestTcp 'www.microsoft.com' 443
        dnsUdp         = (Invoke-GuestPs "try { (Resolve-DnsName www.microsoft.com -DnsOnly -ErrorAction Stop | Select-Object -First 1).Name } catch { 'failed' }")
        httpsFetch     = @(foreach ($i in 1..5) { Invoke-GuestPs "curl.exe -s -o NUL -m 15 -w '%{http_code} dns=%{time_namelookup} tcp=%{time_connect} tls=%{time_appconnect} ip=%{remote_ip}' https://www.microsoft.com/; ' exit=' + `$LASTEXITCODE" })
        hostRpc        = Test-GuestTcp $HostIp 135
        hostLanSmb     = Test-GuestTcp $lan.IPAddress 445
        lanRouterTcp   = Test-GuestTcp $router 80
        lanRouterData  = Test-GuestData $router 80
        privateTen     = Test-GuestTcp '10.0.0.1' 80
        otherMachine   = if ($script:otherIp) { Test-GuestTcp $script:otherIp 47989 } else { 'n/a' }
        hostToSunshine = $up
        downloads      = @(foreach ($i in 1..2) { Invoke-GuestPs "curl.exe -s -o NUL --max-time 120 -w '%{speed_download} %{http_code}' 'https://speed.cloudflare.com/__down?bytes=$bytes'" 150000 })
        routes         = (Invoke-GuestPs "(Get-NetRoute -DestinationPrefix 0.0.0.0/0 | ForEach-Object { `$_.InterfaceAlias + ' via ' + `$_.NextHop }) -join '; '")
    }
}

$Exe = (Resolve-Path $Exe).Path; $Agent = (Resolve-Path $Agent).Path
$tplDir = "C:\GpuVM\.templates\$Template"
$layer = Join-Path $tplDir ((Get-Content (Join-Path $tplDir 'template.json') -Raw | ConvertFrom-Json).layers[-1])
$lan = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike 'vEthernet*' -and $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1
$router = (Get-NetRoute -DestinationPrefix 0.0.0.0/0 -InterfaceIndex $lan.InterfaceIndex | Select-Object -First 1).NextHop
$res.lanProbe = "$($lan.IPAddress) / router $router"

try { $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) }
catch [IO.IOException] { throw "The lab lock is held: $(Get-Content $lock -Raw)" }
$fs.Write([Text.Encoding]::UTF8.GetBytes("lab074 pid=$PID $(Get-Date -Format o)")); $fs.Close()
$wasRunning = (Get-Service GpuVM -ErrorAction SilentlyContinue).Status -eq 'Running'
try {
    if ($wasRunning) { Stop-Service GpuVM -Force; Start-Sleep 2 }
    & schtasks.exe /create /tn $task /tr "`"$Exe`" broker" /sc once /st 00:00 /ru SYSTEM /rl HIGHEST /f 2>$null | Out-Null
    & schtasks.exe /run /tn $task | Out-Null
    Start-Sleep 3
    $null = Invoke-Hc @('create', $root, $name, $layer, '4096', '4', '--gpu', 'nvidia')
    $null = Invoke-Hc @('install-agent', $root, $name, $Agent)
    # A second isolated machine: the first must not reach it (each has its own network).
    $null = Invoke-Hc @('create', $root, "${name}b", $layer, '2048', '2')
    $null = Invoke-Hc @('install-agent', $root, "${name}b", $Agent)
    $other = Invoke-Hc @('start', $root, "${name}b")
    $res.otherStart = $other

    $started = Invoke-Hc @('start', $root, $name)
    $res.isolatedStart = $started
    $agentSec = Wait-Agent
    $netSec = Wait-Internet
    $hostIp = ($started.ip -replace '\.\d+$', '.1')
    $script:otherIp = $other.ip
    $arm = Measure-Guest $started.ip $hostIp
    $arm.agentSec = $agentSec; $arm.internetAfterAgentSec = $netSec
    $res.arms['isolated'] = $arm
    Write-Log "isolated: $($arm | ConvertTo-Json -Compress)"

    $boot = Invoke-GuestPs "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.Ticks"
    $null = Invoke-Ask 'sys.power' '{"action":"restart"}'
    $t = [Diagnostics.Stopwatch]::StartNew(); $now = $boot
    while ($now -eq $boot -and $t.Elapsed.TotalSeconds -lt 300) { Start-Sleep 3; $now = Invoke-GuestPs "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.Ticks"; if ($now -eq 'no answer') { $now = $boot } }
    if ($now -eq $boot) { throw 'the guest did not restart' }
    $agentSec = [math]::Round($t.Elapsed.TotalSeconds, 1)
    $netSec = Wait-Internet
    $arm = [ordered]@{ backAfterRestartSec = $agentSec; internetAfterAgentSec = $netSec; lanRouterData = (Test-GuestData $router 80); hostRpc = (Test-GuestTcp $hostIp 135) }
    $res.arms['isolated-after-restart'] = $arm
    Write-Log "isolated after restart: $($arm | ConvertTo-Json -Compress)"
    $null = Invoke-Hc @('off', $root, $name)
    $null = Invoke-Hc @('off', $root, "${name}b"); $script:otherIp = $null
    $res.networksAfterOff = @(Get-NetAdapter -Name 'vEthernet (GpuVM-*' -ErrorAction SilentlyContinue | ForEach-Object Name)

    $null = Invoke-Hc @('set', $root, $name, '--isolated', 'false')
    $started = Invoke-Hc @('start', $root, $name)
    $agentSec = Wait-Agent
    $netSec = Wait-Internet
    $guestIp = Invoke-GuestPs "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { `$_.IPAddress -notmatch '^(127|169\.254|10\.255)' -and `$_.PrefixOrigin -eq 'Dhcp' } | Select-Object -First 1).IPAddress"
    $icsGw = Invoke-GuestPs "(Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Sort-Object RouteMetric | Select-Object -First 1).NextHop"
    $arm = Measure-Guest $guestIp $icsGw
    $arm.agentSec = $agentSec; $arm.internetAfterAgentSec = $netSec; $arm.guestIp = $guestIp
    $res.arms['control-ics'] = $arm
    Write-Log "control: $($arm | ConvertTo-Json -Compress)"
    $null = Invoke-Hc @('off', $root, $name)
} catch { $res.error = "$_"; $res.errorAt = $_.InvocationInfo.PositionMessage; Write-Log "FAILED: $_ $($_.InvocationInfo.PositionMessage)" }
finally {
    try { $null = Invoke-Hc @('off', $root, $name) } catch { }
    $res.networkEvents = @(Get-ChildItem 'C:\ProgramData\GpuVM' -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-15) } |
        Select-String -Pattern '"event":"network"' -SimpleMatch -ErrorAction SilentlyContinue | ForEach-Object { $_.Line } | Select-Object -Last 6)
    try { $null = Invoke-Hc @('delete', $root, $name) } catch { }
    try { $null = Invoke-Hc @('off', $root, "${name}b") } catch { }
    try { $null = Invoke-Hc @('delete', $root, "${name}b") } catch { }
    try { $null = Invoke-Hc @('network-delete') } catch { }
    & schtasks.exe /end /tn $task 2>$null | Out-Null
    Get-CimInstance Win32_Process -Filter "Name='gpuvm-host.exe'" | Where-Object ExecutablePath -eq $Exe | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    & schtasks.exe /delete /tn $task /f 2>$null | Out-Null
    if ($wasRunning) { Start-Service GpuVM }
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    $res.totalSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $res | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $outDir "$runId.json")
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
    Write-Log "done -> out/$runId.json; left behind: root=$(Test-Path $root) lock=$(Test-Path $lock) service=$((Get-Service GpuVM).Status)"
}
