# Lab 070: network isolation of HCS machines (HCN endpoint ACLs), the same rules GpuVM applies to Hyper-V machines.
# One machine, two arms: isolated (default) and not isolated (the positive control: the same probes must get through).
# Probes run in the guest through the agent (sys.exec); the host probes Sunshine on the guest.
#   pwsh -NoProfile -File labs/070-hcs-isolation/run.ps1
param([string]$Template = 'normal-tpl',
    [string]$Exe = (Join-Path $PSScriptRoot '..\..\app\host\target\debug\gpuvm-host.exe'),
    [string]$Agent = (Join-Path $PSScriptRoot '..\..\guest\agent\dist\gpuvm-agent.exe'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = $PSScriptRoot
$root = 'C:\GpuVM\.lab070'; $name = 'm070'; $lock = 'C:\GpuVM\.lab-lock'; $task = 'GpuVMLab070Broker'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $here 'out'; $null = New-Item -ItemType Directory -Force $outDir
$res = [ordered]@{ runId = $runId; arms = [ordered]@{} }
$sw = [Diagnostics.Stopwatch]::StartNew()
function Log([string]$m) { Write-Host ("[{0,6:n1}s] {1}" -f $sw.Elapsed.TotalSeconds, $m) }
function Hcs([string[]]$A) { $o = (& $Exe hcs @A | Select-Object -Last 1) | ConvertFrom-Json; if (-not $o.ok) { throw "hcs $($A[0]): $($o.error)" }; $o.result }
function Ask([string]$Method, [string]$Params = '{}') {
    $o = (& $Exe hcs ask $name $Method $Params | Select-Object -Last 1) | ConvertFrom-Json
    if (-not $o.ok -or -not $o.result.ok) { return $null }
    $o.result.result
}
function GuestTcp([string]$Target, [int]$Port) {
    $ps = "try { `$c = [Net.Sockets.TcpClient]::new(); if (`$c.ConnectAsync('$Target', $Port).Wait(3000) -and `$c.Connected) { 'open' } else { 'blocked' } } catch { 'blocked' }"
    $r = Ask 'sys.exec' (@{ file = 'WindowsPowerShell\v1.0\powershell.exe'; args = @('-NoProfile', '-Command', $ps); timeoutMs = 15000 } | ConvertTo-Json -Compress)
    if ($r) { $r.stdout.Trim() } else { 'no answer' }
}

$Exe = (Resolve-Path $Exe).Path; $Agent = (Resolve-Path $Agent).Path
$tplDir = "C:\GpuVM\.templates\$Template"
$layer = Join-Path $tplDir ((Get-Content (Join-Path $tplDir 'template.json') -Raw | ConvertFrom-Json).layers[-1])
# A LAN address of this PC (not GpuVM's network, not the Default Switch): what an isolated guest must not reach.
$lan = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike 'vEthernet*' -and $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1
$res.lanProbe = "$($lan.IPAddress) ($($lan.InterfaceAlias))"

try { $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) }
catch [IO.IOException] { throw "The lab lock is held: $(Get-Content $lock -Raw)" }
$fs.Write([Text.Encoding]::UTF8.GetBytes("lab070 pid=$PID $(Get-Date -Format o)")); $fs.Close()
$wasRunning = (Get-Service GpuVM -ErrorAction SilentlyContinue).Status -eq 'Running'
try {
    if ($wasRunning) { Stop-Service GpuVM -Force }
    & schtasks.exe /create /tn $task /tr "`"$Exe`" broker" /sc once /st 00:00 /ru SYSTEM /rl HIGHEST /f | Out-Null
    & schtasks.exe /run /tn $task | Out-Null
    $t = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path '\\.\pipe\gpuvm-agent')) { if ($t.Elapsed.TotalSeconds -gt 20) { throw 'no broker' }; Start-Sleep -Milliseconds 300 }
    $null = Hcs @('create', $root, $name, $layer, '4096', '4', '--gpu', 'nvidia')
    $null = Hcs @('install-agent', $root, $name, $Agent)
    foreach ($isolated in 'true', 'false') {
        $null = Hcs @('set', $root, $name, '--isolated', $isolated)
        $null = Hcs @('start', $root, $name)
        $t = [Diagnostics.Stopwatch]::StartNew(); $info = $null
        # The agent answers before DHCP does: wait for an address too.
        while ($t.Elapsed.TotalSeconds -lt 240) {
            $info = Ask 'sys.info'
            if ($info -and @($info.ipv4).Count) { break }
            Start-Sleep 2
        }
        if (-not $info -or -not @($info.ipv4).Count) { throw "no agent or no address ($isolated)" }
        $ip = @($info.ipv4)[0]
        # Sunshine starts at sign-in, later than the agent.
        $s = [Diagnostics.Stopwatch]::StartNew()
        while ($s.Elapsed.TotalSeconds -lt 120) {
            $up = try { $c = [Net.Sockets.TcpClient]::new(); [bool]($c.ConnectAsync($ip, 47989).Wait(2000) -and $c.Connected) } catch { $false }
            if ($up) { break }
            Start-Sleep 2
        }
        $gw = ($ip -replace '\.\d+$', '.1')
        $hostToSunshine = try { $c = [Net.Sockets.TcpClient]::new(); [bool]($c.ConnectAsync($ip, 47989).Wait(3000) -and $c.Connected) } catch { $false }
        $arm = [ordered]@{
            guestIp          = $ip
            internet443      = GuestTcp 'www.microsoft.com' 443
            dns              = (Ask 'sys.exec' '{"file":"nslookup.exe","args":["www.microsoft.com"],"timeoutMs":10000}').stdout -match 'Address(es)?:\s+\d'
            hostGatewaySmb   = GuestTcp $gw 445
            lanSmb           = GuestTcp $lan.IPAddress 445
            lanRdpOrHttp     = GuestTcp $lan.IPAddress 135
            hostToSunshine   = $hostToSunshine
        }
        $res.arms["isolated=$isolated"] = $arm
        Log "isolated=${isolated}: $($arm | ConvertTo-Json -Compress)"
        $null = Hcs @('off', $root, $name)
    }
} catch { $res.error = "$_"; $res.errorAt = $_.InvocationInfo.PositionMessage; Log "FAILED: $_ $($_.InvocationInfo.PositionMessage)" }
finally {
    try { & $Exe hcs off $root $name | Out-Null; & $Exe hcs delete $root $name | Out-Null } catch { }
    & $Exe hcs network-delete | Out-Null
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
