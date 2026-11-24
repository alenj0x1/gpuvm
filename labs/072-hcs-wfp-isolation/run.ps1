# Lab 072: isolation of HCS machines with Windows Filtering Platform filters on the host interface of GpuVM's ICS
# network (labs 070 and 071: HCN endpoint ACLs are not enforced on client Windows, on ICS or NAT). The machine keeps
# DHCP; the same probes run without filters (control) and with them, plus a device on the LAN other than the host.
#   pwsh -NoProfile -File labs/072-hcs-wfp-isolation/run.ps1
param([string]$Template = 'normal-tpl',
    [string]$Exe = (Join-Path $PSScriptRoot '..\..\app\host\target\debug\gpuvm-host.exe'),
    [string]$Agent = (Join-Path $PSScriptRoot '..\..\guest\agent\dist\gpuvm-agent.exe'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = $PSScriptRoot
$root = 'C:\GpuVM\.lab072'; $name = 'm072'; $lock = 'C:\GpuVM\.lab-lock'; $task = 'GpuVMLab072Broker'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $here 'out'; $null = New-Item -ItemType Directory -Force $outDir
$res = [ordered]@{ runId = $runId; arms = [ordered]@{} }
$sw = [Diagnostics.Stopwatch]::StartNew()
function Log([string]$m) { Write-Host ("[{0,6:n1}s] {1}" -f $sw.Elapsed.TotalSeconds, $m) }
function Invoke-Hc([string[]]$A) { $o = (& $Exe hcs @A | Select-Object -Last 1) | ConvertFrom-Json; if (-not $o.ok) { throw "hcs $($A[0]): $($o.error)" }; $o.result }
function Invoke-Ask([string]$Method, [string]$Params = '{}') {
    $o = (& $Exe hcs ask $name $Method $Params | Select-Object -Last 1) | ConvertFrom-Json
    if (-not $o.ok -or -not $o.result.ok) { return $null }
    $o.result.result
}
function Invoke-GuestPs([string]$Script, [int]$TimeoutMs = 20000) {
    $r = Invoke-Ask 'sys.exec' (@{ file = 'WindowsPowerShell\v1.0\powershell.exe'; args = @('-NoProfile', '-Command', $Script); timeoutMs = $TimeoutMs } | ConvertTo-Json -Compress)
    if ($r) { "$($r.stdout)".Trim() } else { 'no answer' }
}
function Test-GuestTcp([string]$Target, [int]$Port) {
    Invoke-GuestPs "try { `$c = [Net.Sockets.TcpClient]::new(); if (`$c.ConnectAsync('$Target', $Port).Wait(3000) -and `$c.Connected) { 'open' } else { 'blocked' } } catch { 'blocked' }"
}

$Exe = (Resolve-Path $Exe).Path; $Agent = (Resolve-Path $Agent).Path
$tplDir = "C:\GpuVM\.templates\$Template"
$layer = Join-Path $tplDir ((Get-Content (Join-Path $tplDir 'template.json') -Raw | ConvertFrom-Json).layers[-1])
$lan = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike 'vEthernet*' -and $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1
$res.lanProbe = "$($lan.IPAddress) ($($lan.InterfaceAlias))"
$router = (Get-NetRoute -DestinationPrefix 0.0.0.0/0 -InterfaceIndex $lan.InterfaceIndex | Select-Object -First 1).NextHop
$res.lanRouter = $router

try { $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) }
catch [IO.IOException] { throw "The lab lock is held: $(Get-Content $lock -Raw)" }
$fs.Write([Text.Encoding]::UTF8.GetBytes("lab072 pid=$PID $(Get-Date -Format o)")); $fs.Close()
$wasRunning = (Get-Service GpuVM -ErrorAction SilentlyContinue).Status -eq 'Running'
try {
    if ($wasRunning) { Stop-Service GpuVM -Force; Start-Sleep 2 }
    & schtasks.exe /create /tn $task /tr "`"$Exe`" broker" /sc once /st 00:00 /ru SYSTEM /rl HIGHEST /f 2>$null | Out-Null
    & schtasks.exe /run /tn $task | Out-Null
    Start-Sleep 3
    $null = Invoke-Hc @('create', $root, $name, $layer, '4096', '4', '--gpu', 'nvidia')
    $null = Invoke-Hc @('install-agent', $root, $name, $Agent)
    $null = Invoke-Hc @('start', $root, $name)
    $t = [Diagnostics.Stopwatch]::StartNew(); $info = $null
    function Get-Ip4($i) { if ($i -and $i.PSObject.Properties['ipv4']) { @(@($i.ipv4) | Where-Object { $_ -match '^\d' -and $_ -notmatch '^169\.254' })[0] } }
    while (-not (Get-Ip4 $info) -and $t.Elapsed.TotalSeconds -lt 180) { $info = Invoke-Ask 'sys.info'; if (-not (Get-Ip4 $info)) { Start-Sleep 2 } }
    $ip = Get-Ip4 $info
    if (-not $ip) { throw "no agent or no DHCP address" }
    $res.guestIp = $ip; $res.agentSec = [math]::Round($t.Elapsed.TotalSeconds, 1)
    $gw = Invoke-GuestPs "(Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Select-Object -First 1).NextHop"
    $res.gateway = $gw
    foreach ($filters in 'off', 'on', 'fwd', 'outpkt', 'connect') {
        $null = Invoke-Hc @('wfp', 'off')
        if ($filters -ne 'off') {
            $env:GPUVM_WFP_DIAG = if ($filters -eq 'on') { $null } else { "${filters}:$router" }
            $res.wfp = Invoke-Hc @('wfp', 'on')
        }
        Start-Sleep 2
        $s = [Diagnostics.Stopwatch]::StartNew(); $up = $false
        while (-not $up -and $s.Elapsed.TotalSeconds -lt 20) {
            $up = try { $c = [Net.Sockets.TcpClient]::new(); [bool]($c.ConnectAsync($ip, 47989).Wait(2000) -and $c.Connected) } catch { $false }
            if (-not $up) { Start-Sleep 2 }
        }
        $arm = [ordered]@{
            internetByIp   = Test-GuestTcp '1.1.1.1' 443
            internetByName = Test-GuestTcp 'www.microsoft.com' 443
            dnsViaHost     = (Invoke-GuestPs "try { (Resolve-DnsName www.microsoft.com -Server $gw -DnsOnly -ErrorAction Stop | Select-Object -First 1).Name } catch { 'failed' }")
            hostGatewaySmb = Test-GuestTcp $gw 445
            hostGatewayRpc = Test-GuestTcp $gw 135
            hostLanSmb     = Test-GuestTcp $lan.IPAddress 445
            hostLanRpc     = Test-GuestTcp $lan.IPAddress 135
            lanRouterHttp  = Test-GuestTcp $router 80
            lanRouterDns   = Test-GuestTcp $router 53
            hostToSunshine = $up
        }
        $res.arms["filters=$filters"] = $arm
        Log "filters=${filters}: $($arm | ConvertTo-Json -Compress)"
    }
    $null = Invoke-Hc @('wfp', 'off')
    $res.filtersLeft = @(& netsh wfp show filters file=- 2>$null | Select-String 'GpuVM').Count
} catch { $res.error = "$_"; $res.errorAt = $_.InvocationInfo.PositionMessage; Log "FAILED: $_ $($_.InvocationInfo.PositionMessage)" }
finally {
    try { $null = Invoke-Hc @('wfp', 'off') } catch { }
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
    Log "done -> out/$runId.json; left behind: root=$(Test-Path $root) lock=$(Test-Path $lock) service=$((Get-Service GpuVM).Status)"
}
