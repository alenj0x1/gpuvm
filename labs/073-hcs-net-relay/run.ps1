# Lab 073: internet for an isolated HCS machine through a relay over its Hyper-V socket (labs 070-072: no Windows NAT
# can be filtered on client editions). Relay arm: the machine sits on an HCN Internal network (only the host, locked
# by host WFP filters, Moonlight open) and its internet goes through Wintun + a user-mode stack in the guest and the
# host relay, which refuses every non-public destination. Control arm: the same machine on GpuVM's ICS network.
#   pwsh -NoProfile -File labs/073-hcs-net-relay/run.ps1 -Wintun <folder with wintun.dll>
param([Parameter(Mandatory)][string]$Wintun, [string]$Template = 'normal-tpl', [string]$Ip = '192.168.166.10',
    [string]$Exe = (Join-Path $PSScriptRoot '..\..\app\host\target\debug\gpuvm-host.exe'),
    [string]$Agent = (Join-Path $PSScriptRoot '..\..\guest\agent\dist\gpuvm-agent.exe'),
    [string]$Relay = (Join-Path $PSScriptRoot 'relay\target\release\netrelay.exe'),
    [int]$DownloadMB = 50)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = $PSScriptRoot
$root = 'C:\GpuVM\.lab073'; $name = 'm073'; $lock = 'C:\GpuVM\.lab-lock'; $task = 'GpuVMLab073Broker'
$service = '6e1a3c5f-1d2b-4f0e-9a65-0657b0c0e073'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $here 'out'; $null = New-Item -ItemType Directory -Force $outDir
$res = [ordered]@{ runId = $runId; ip = $Ip; arms = [ordered]@{} }
$sw = [Diagnostics.Stopwatch]::StartNew()
function Write-Log([string]$m) { Write-Host ("[{0,6:n1}s] {1}" -f $sw.Elapsed.TotalSeconds, $m) }
function Invoke-Hc([string[]]$A) { $o = (& $Exe hcs @A | Select-Object -Last 1) | ConvertFrom-Json; if (-not $o.ok) { throw "hcs $($A[0]): $($o.error)" }; $o.result }
function Invoke-Ask([string]$Method, [string]$Params = '{}', [string]$Blob) {
    $a = @('ask', $name, $Method, $Params); if ($Blob) { $a += @('--blob', $Blob) }
    $o = (& $Exe hcs @a | Select-Object -Last 1) | ConvertFrom-Json
    if (-not $o.ok -or -not $o.result.ok) { return $null }
    $o.result.result
}
function Invoke-GuestPs([string]$Script, [int]$TimeoutMs = 30000) {
    $r = Invoke-Ask 'sys.exec' (@{ file = 'WindowsPowerShell\v1.0\powershell.exe'; args = @('-NoProfile', '-Command', $Script); timeoutMs = $TimeoutMs } | ConvertTo-Json -Compress)
    if ($r) { "$($r.stdout)".Trim() } else { 'no answer' }
}
function Test-GuestTcp([string]$Target, [int]$Port) {
    Invoke-GuestPs "try { `$c = [Net.Sockets.TcpClient]::new(); if (`$c.ConnectAsync('$Target', $Port).Wait(3000) -and `$c.Connected) { 'open' } else { 'blocked' } } catch { 'blocked' }"
}
function Test-GuestData([string]$Target, [int]$Port) {
    $r = Invoke-GuestPs "curl.exe -s -o NUL -m 5 -w '%{http_code}' http://${Target}:$Port/; ' exit=' + `$LASTEXITCODE"
    $r
}
function Wait-Agent {
    $t = [Diagnostics.Stopwatch]::StartNew()
    while ($t.Elapsed.TotalSeconds -lt 180) { if (Invoke-Ask 'sys.info') { return [math]::Round($t.Elapsed.TotalSeconds, 1) }; Start-Sleep 2 }
    throw 'no agent'
}
function Measure-Guest([string]$GuestIp, [string]$HostGw) {
    $s = [Diagnostics.Stopwatch]::StartNew(); $up = $false
    while (-not $up -and $s.Elapsed.TotalSeconds -lt 90) {
        $up = try { $c = [Net.Sockets.TcpClient]::new(); [bool]($c.ConnectAsync($GuestIp, 47989).Wait(2000) -and $c.Connected) } catch { $false }
        if (-not $up) { Start-Sleep 2 }
    }
    $bytes = $DownloadMB * 1000000
    $dl = foreach ($i in 1..2) {
        Invoke-GuestPs "curl.exe -s -o NUL --max-time 120 -w '%{speed_download} %{time_connect} %{http_code}' 'https://speed.cloudflare.com/__down?bytes=$bytes'" 150000
    }
    $connect = Invoke-GuestPs ("`$t = foreach (`$i in 1..5) { `$w = [Diagnostics.Stopwatch]::StartNew(); `$c = [Net.Sockets.TcpClient]::new(); " +
        "if (`$c.ConnectAsync('1.1.1.1', 443).Wait(3000)) { `$w.Elapsed.TotalMilliseconds }; `$c.Dispose() }; " +
        "if (`$t) { [math]::Round((`$t | Measure-Object -Average).Average, 1) } else { 'failed' }")
    [ordered]@{
        internetByIp   = Test-GuestTcp '1.1.1.1' 443
        internetByName = Test-GuestTcp 'www.microsoft.com' 443
        dnsUdp         = (Invoke-GuestPs "try { (Resolve-DnsName www.microsoft.com -Server 1.1.1.1 -DnsOnly -ErrorAction Stop | Select-Object -First 1).Name } catch { 'failed' }")
        httpsFetch     = (Invoke-GuestPs "curl.exe -s -o NUL -w '%{http_code}' https://www.microsoft.com/")
        hostGatewayRpc = Test-GuestTcp $HostGw 135
        hostGatewaySmb = Test-GuestTcp $HostGw 445
        hostLanRpc     = Test-GuestTcp $lan.IPAddress 135
        hostLanSmb     = Test-GuestTcp $lan.IPAddress 445
        lanRouterHttp  = Test-GuestTcp $router 80
        lanRouterData  = Test-GuestData $router 80
        hostLanData    = Test-GuestData $lan.IPAddress 135
        lanRouterDns   = Test-GuestTcp $router 53
        privateTen     = Test-GuestTcp '10.0.0.1' 80
        hostToSunshine = $up
        connectMs      = $connect
        downloads      = @($dl)
    }
}

$Exe = (Resolve-Path $Exe).Path; $Agent = (Resolve-Path $Agent).Path; $Relay = (Resolve-Path $Relay).Path
$dll = (Resolve-Path (Join-Path $Wintun 'wintun.dll')).Path
if ((Get-AuthenticodeSignature $dll).Status -ne 'Valid') { throw 'wintun.dll is not validly signed' }
$tplDir = "C:\GpuVM\.templates\$Template"
$layer = Join-Path $tplDir ((Get-Content (Join-Path $tplDir 'template.json') -Raw | ConvertFrom-Json).layers[-1])
$lan = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike 'vEthernet*' -and $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1
$router = (Get-NetRoute -DestinationPrefix 0.0.0.0/0 -InterfaceIndex $lan.InterfaceIndex | Select-Object -First 1).NextHop
$gw = ($Ip -replace '\.\d+$', '.1')
$res.lanProbe = "$($lan.IPAddress) / router $router"

try { $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) }
catch [IO.IOException] { throw "The lab lock is held: $(Get-Content $lock -Raw)" }
$fs.Write([Text.Encoding]::UTF8.GetBytes("lab073 pid=$PID $(Get-Date -Format o)")); $fs.Close()
$wasRunning = (Get-Service GpuVM -ErrorAction SilentlyContinue).Status -eq 'Running'
$hostRelay = $null
try {
    if ($wasRunning) { Stop-Service GpuVM -Force; Start-Sleep 2 }
    & schtasks.exe /create /tn $task /tr "`"$Exe`" broker" /sc once /st 00:00 /ru SYSTEM /rl HIGHEST /f 2>$null | Out-Null
    & schtasks.exe /run /tn $task | Out-Null
    Start-Sleep 3
    $null = Invoke-Hc @('create', $root, $name, $layer, '4096', '4', '--gpu', 'nvidia', '--service', $service)
    $null = Invoke-Hc @('install-agent', $root, $name, $Agent)

    # Control arm: GpuVM's ICS network with DHCP; run first, on the fresh disk.
    $null = Invoke-Hc @('set', $root, $name, '--network', 'ics', '--isolated', 'false')
    $null = Invoke-Hc @('start', $root, $name)
    $agentSec = Wait-Agent
    $t = [Diagnostics.Stopwatch]::StartNew(); $guestIp = $null
    while (-not $guestIp -and $t.Elapsed.TotalSeconds -lt 90) {
        $guestIp = Invoke-GuestPs "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { `$_.IPAddress -notmatch '^(127|169\.254|10\.255)' } | Select-Object -First 1).IPAddress"
        if ($guestIp -notmatch '^\d') { $guestIp = $null; Start-Sleep 2 }
    }
    $icsGw = Invoke-GuestPs "(Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Sort-Object RouteMetric | Select-Object -First 1).NextHop"
    $arm = Measure-Guest $guestIp $icsGw
    $arm.agentSec = $agentSec; $arm.guestIp = $guestIp
    $res.arms['control-ics'] = $arm
    Write-Log "control: $($arm | ConvertTo-Json -Compress)"
    $null = Invoke-Hc @('off', $root, $name)
    # Relay arm.
    $env:GPUVM_NAT_TYPE = 'Internal'
    $null = Invoke-Hc @('set', $root, $name, '--network', 'nat', '--ip', $Ip, '--isolated', 'false')
    $started = Invoke-Hc @('start', $root, $name)
    $vmId = $started.runtimeId
    $hostLog = Join-Path $outDir "$runId-host.log"
    $hostRelay = Start-Process $Relay -ArgumentList 'host', $vmId -PassThru -WindowStyle Hidden -RedirectStandardError $hostLog
    $agentSec = Wait-Agent
    $res.wfp = Invoke-Hc @('wfp', 'on', $gw)
    $null = Invoke-GuestPs "New-Item -ItemType Directory -Force C:\ProgramData\GpuVM\Net | Out-Null"
    $null = Invoke-Ask 'sys.write' '{"path":"C:\\ProgramData\\GpuVM\\Net\\netrelay.exe"}' $Relay
    $null = Invoke-Ask 'sys.write' '{"path":"C:\\ProgramData\\GpuVM\\Net\\wintun.dll"}' $dll
    $setup = Invoke-GuestPs ("`$a = Get-NetAdapter | Where-Object { `$_.Status -eq 'Up' -and `$_.InterfaceDescription -notlike 'Wintun*' } | Select-Object -First 1; " +
        "Get-NetIPAddress -InterfaceIndex `$a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:`$false -ErrorAction SilentlyContinue; " +
        "New-NetIPAddress -InterfaceIndex `$a.ifIndex -IPAddress $Ip -PrefixLength 24 | Out-Null; " +
        "schtasks.exe /create /tn GpuVMNetRelay /tr 'C:\ProgramData\GpuVM\Net\netrelay.exe guest C:\ProgramData\GpuVM\Net\wintun.dll' /sc onstart /ru SYSTEM /rl HIGHEST /f | Out-Null; " +
        "schtasks.exe /run /tn GpuVMNetRelay | Out-Null; " +
        "`$t = 0; while (-not (Get-NetAdapter -Name GpuVMNet -ErrorAction SilentlyContinue) -and `$t -lt 30) { Start-Sleep 1; `$t++ }; " +
        "`$n = Get-NetAdapter -Name GpuVMNet; New-NetRoute -InterfaceIndex `$n.ifIndex -DestinationPrefix 0.0.0.0/0 -NextHop 10.255.255.1 -RouteMetric 1 | Out-Null; " +
        "Set-DnsClientServerAddress -InterfaceIndex `$n.ifIndex -ServerAddresses 1.1.1.1; 'tun ' + `$n.ifIndex + ' after ' + `$t + ' s'")
    Write-Log "relay arm: agent $agentSec s; $setup"
    Start-Sleep 3
    $arm = Measure-Guest $Ip $gw
    $arm.agentSec = $agentSec; $arm.setup = $setup
    Start-Sleep 2
    $res.hostRefused = @(Get-Content $hostLog | Where-Object { $_ -like 'refused *' } | ForEach-Object { $_.Substring(8) } | Sort-Object -Unique)
    $res.arms['relay'] = $arm
    Write-Log "relay: $($arm | ConvertTo-Json -Compress)"
    $null = Invoke-Hc @('wfp', 'off', $gw)
    Stop-Process -Id $hostRelay.Id -Force -ErrorAction SilentlyContinue; $hostRelay = $null
    $null = Invoke-GuestPs "schtasks.exe /delete /tn GpuVMNetRelay /f | Out-Null"
    $null = Invoke-Hc @('off', $root, $name)
    Remove-Item Env:GPUVM_NAT_TYPE

} catch { $res.error = "$_"; $res.errorAt = $_.InvocationInfo.PositionMessage; Write-Log "FAILED: $_ $($_.InvocationInfo.PositionMessage)" }
finally {
    if ($hostRelay) { Stop-Process -Id $hostRelay.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:GPUVM_NAT_TYPE -ErrorAction SilentlyContinue
    try { $null = Invoke-Hc @('wfp', 'off', $gw) } catch { }
    try { $null = Invoke-Hc @('off', $root, $name) } catch { }
    try { $null = Invoke-Hc @('delete', $root, $name) } catch { }
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
