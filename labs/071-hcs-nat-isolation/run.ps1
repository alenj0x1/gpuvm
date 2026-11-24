# Lab 071: isolation of HCS machines on a NAT network with fixed addresses (lab 070 showed that on the ICS network
# the endpoint ACLs are stored but not enforced, and that the filtering extension that enforces them breaks ICS's
# DHCP). The agent sets the guest's address; the same probes as lab 070 run isolated and, as the control, not isolated.
#   pwsh -NoProfile -File labs/071-hcs-nat-isolation/run.ps1
param([string]$Template = 'normal-tpl', [string]$Ip = '192.168.166.10',
    [string]$Exe = (Join-Path $PSScriptRoot '..\..\app\host\target\debug\gpuvm-host.exe'),
    [string]$Agent = (Join-Path $PSScriptRoot '..\..\guest\agent\dist\gpuvm-agent.exe'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = $PSScriptRoot
$root = 'C:\GpuVM\.lab071'; $name = 'm071'; $lock = 'C:\GpuVM\.lab-lock'; $task = 'GpuVMLab071Broker'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $here 'out'; $null = New-Item -ItemType Directory -Force $outDir
$res = [ordered]@{ runId = $runId; ip = $Ip; arms = [ordered]@{} }
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
$gw = ($Ip -replace '\.\d+$', '.1')
$router = (Get-NetRoute -DestinationPrefix 0.0.0.0/0 -InterfaceIndex $lan.InterfaceIndex | Select-Object -First 1).NextHop

try { $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) }
catch [IO.IOException] { throw "The lab lock is held: $(Get-Content $lock -Raw)" }
$fs.Write([Text.Encoding]::UTF8.GetBytes("lab071 pid=$PID $(Get-Date -Format o)")); $fs.Close()
$wasRunning = (Get-Service GpuVM -ErrorAction SilentlyContinue).Status -eq 'Running'
try {
    if ($wasRunning) { Stop-Service GpuVM -Force; Start-Sleep 2 }
    & schtasks.exe /create /tn $task /tr "`"$Exe`" broker" /sc once /st 00:00 /ru SYSTEM /rl HIGHEST /f 2>$null | Out-Null
    & schtasks.exe /run /tn $task | Out-Null
    Start-Sleep 3
    $null = Invoke-Hc @('create', $root, $name, $layer, '4096', '4', '--gpu', 'nvidia')
    $null = Invoke-Hc @('install-agent', $root, $name, $Agent)
    foreach ($isolated in 'true', 'false') {
        $null = Invoke-Hc @('set', $root, $name, '--network', 'nat', '--ip', $Ip, '--isolated', $isolated)
        $null = Invoke-Hc @('start', $root, $name)
        $t = [Diagnostics.Stopwatch]::StartNew(); $info = $null
        while (-not $info -and $t.Elapsed.TotalSeconds -lt 180) { $info = Invoke-Ask 'sys.info'; if (-not $info) { Start-Sleep 2 } }
        if (-not $info) { throw "no agent ($isolated)" }
        $agentSec = [math]::Round($t.Elapsed.TotalSeconds, 1)
        $set = Invoke-GuestPs ("`$a = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1; " +
            "Get-NetIPAddress -InterfaceIndex `$a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:`$false -ErrorAction SilentlyContinue; " +
            "Remove-NetRoute -InterfaceIndex `$a.ifIndex -DestinationPrefix 0.0.0.0/0 -Confirm:`$false -ErrorAction SilentlyContinue; " +
            "New-NetIPAddress -InterfaceIndex `$a.ifIndex -IPAddress $Ip -PrefixLength 24 -DefaultGateway $gw | Out-Null; " +
            "Set-DnsClientServerAddress -InterfaceIndex `$a.ifIndex -ServerAddresses $gw,1.1.1.1; 'set ' + `$a.Name")
        if ($isolated -eq 'true' -and -not $env:LAB_NO_WFP) { $res.wfp = Invoke-Hc @('wfp', 'on', $gw) }
        Start-Sleep 5
        $s = [Diagnostics.Stopwatch]::StartNew(); $up = $false
        while (-not $up -and $s.Elapsed.TotalSeconds -lt 120) {
            $up = try { $c = [Net.Sockets.TcpClient]::new(); [bool]($c.ConnectAsync($Ip, 47989).Wait(2000) -and $c.Connected) } catch { $false }
            if (-not $up) { Start-Sleep 2 }
        }
        $arm = [ordered]@{
            agentSec       = $agentSec
            addressSet     = $set
            internetByIp   = Test-GuestTcp '1.1.1.1' 443
            internetByName = Test-GuestTcp 'www.microsoft.com' 443
            dnsViaHost     = (Invoke-GuestPs "try { (Resolve-DnsName www.microsoft.com -Server $gw -DnsOnly -ErrorAction Stop | Select-Object -First 1).Name } catch { 'failed' }")
            hostGatewaySmb = Test-GuestTcp $gw 445
            lanSmb         = Test-GuestTcp $lan.IPAddress 445
            lanRpc         = Test-GuestTcp $lan.IPAddress 135
            hostGatewayRpc = Test-GuestTcp $gw 135
            lanRouterHttp  = Test-GuestTcp $router 80
            hostToSunshine = $up
        }
        $res.arms["isolated=$isolated"] = $arm
        Log "isolated=${isolated}: $($arm | ConvertTo-Json -Compress)"
        $null = Invoke-Hc @('wfp', 'off', $gw)
        $null = Invoke-Hc @('off', $root, $name)
    }
} catch { $res.error = "$_"; $res.errorAt = $_.InvocationInfo.PositionMessage; Log "FAILED: $_ $($_.InvocationInfo.PositionMessage)" }
finally {
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
    Log "done -> out/$runId.json; left behind: root=$(Test-Path $root) lock=$(Test-Path $lock) service=$((Get-Service GpuVM).Status)"
}
