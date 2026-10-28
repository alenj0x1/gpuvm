# Lab 010: what a GpuVM VM can reach on the network, without and with extended port ACLs on its vSwitch port.
# Run elevated with PowerShell 7: pwsh -File labs\010-network-isolation\probe.ps1 -Name win10
# Every change is reverted at the end (ACLs it added, the temporary listener and firewall rule, the VM's power state).
# -Installed checks GpuVM's own isolation instead: opens the VM as the app does (Connect-GpuVM, which applies it)
# and measures once, leaving the VM and Moonlight open to check the stream.
param(
    [switch]$Installed,
    [string]$Name = (Get-VM | Where-Object Notes -like "Creada con GpuVM*" | Select-Object -First 1).Name,
    [string]$OutFile = (Join-Path $PSScriptRoot "out\probe-$(Get-Date -Format yyyyMMdd-HHmmss).json")
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$module = Get-Module GpuVM

$labPort = 47321
$echoPort = 48002
$ruleName = 'GpuVM-Lab010'
$aclTag = 10000  # weights the lab adds start here, so only those are removed

$state = & $module { param($n) Get-GpuVMState -Name $n } $Name
$guest = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state
if (-not $guest) { throw 'La VM no tiene la contraseña de Windows guardada; el laboratorio la necesita para medir desde dentro.' }

$vm = Get-VM -Name $Name
$startedHere = $false
if ($Installed) { Connect-GpuVM -Name $Name }
elseif ($vm.State -ne 'Running') {
    Start-VM -Name $Name
    $startedHere = $true
}
& $module { param($n, $c) Wait-GuestReady -Name $n -Credential $c } $Name $guest
$endpoint = & $module { param($n) Get-GpuVMEndpoint -Name $n -TimeoutSec 600 } $Name
$switch = (Get-VMNetworkAdapter -VMName $Name | Select-Object -First 1).SwitchName
$hostIp = $endpoint.HostAddress
$hostLl = (Get-NetIPAddress -InterfaceAlias "vEthernet ($switch)" -AddressFamily IPv6 | Where-Object IPAddress -like 'fe80*' | Select-Object -First 1).IPAddress -replace '%\d+$', ''
$lan = Get-NetIPConfiguration | Where-Object IPv4DefaultGateway | Select-Object -First 1
$lanIp = $lan.IPv4Address.IPAddress
$gateway = $lan.IPv4DefaultGateway.NextHop
$listening = @(Get-NetTCPConnection -State Listen | Where-Object { $_.LocalAddress -in '0.0.0.0', '::', $hostIp } |
    Select-Object -ExpandProperty LocalPort -Unique | Sort-Object | Select-Object -First 25)

# Temporary listener on every host address, allowed by the firewall only from the VM's switch subnet,
# so what is measured is the ACL and not the host firewall.
New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $labPort -Action Allow -RemoteAddress "$hostIp/20", 'fe80::/10' | Out-Null
$listener = Start-ThreadJob -ArgumentList $labPort -ScriptBlock {
    param($port)
    $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::IPv6Any, $port)
    $l.Server.DualMode = $true
    $l.Start()
    $deadline = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $deadline) {
        if ($l.Pending()) { $l.AcceptTcpClient().Close() } else { Start-Sleep -Milliseconds 50 }
    }
    $l.Stop()
}

$guestProbe = {
    param($hostIp, $hostLl, $lanIp, $gateway, $listening, $labPort, $echoPort)
    function Test-Tcp($address, $port) {
        $family = if ($address.Contains(':')) { 'InterNetworkV6' } else { 'InterNetwork' }
        $c = [Net.Sockets.TcpClient]::new([Net.Sockets.AddressFamily]$family)
        try { $c.ConnectAsync($address, $port).Wait(1500) -and $c.Connected } catch { $false } finally { $c.Dispose() }
    }
    $ifIndex = (Get-NetIPConfiguration | Where-Object IPv4DefaultGateway | Select-Object -First 1).InterfaceIndex
    $ll = if ($hostLl) { "$hostLl%$ifIndex" } else { $null }
    $r = [ordered]@{}
    $r['host.labPort'] = Test-Tcp $hostIp $labPort
    $r['host.lanIp.labPort'] = Test-Tcp $lanIp $labPort
    if ($ll) { $r['host.ipv6ll.labPort'] = Test-Tcp $ll $labPort }
    $r['host.openPorts'] = @($listening | Where-Object { Test-Tcp $hostIp $_ })
    $r['host.dns'] = [bool]$(try { Resolve-DnsName example.com -Server $hostIp -DnsOnly -QuickTimeout -ErrorAction Stop } catch { $null })
    $r['lan.gateway.tcp80'] = Test-Tcp $gateway 80
    $r['lan.gateway.tcp53'] = Test-Tcp $gateway 53
    $r['lan.gateway.ping'] = [bool]((ping.exe -n 1 -w 1000 $gateway) -match 'TTL=')
    $r['internet.tcp443'] = Test-Tcp '1.1.1.1' 443
    $r['internet.dns'] = [bool]$(try { Resolve-DnsName example.com -DnsOnly -QuickTimeout -ErrorAction Stop } catch { $null })
    $r['internet.http'] = $(try { (Invoke-WebRequest http://www.msftconnecttest.com/connecttest.txt -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200 } catch { $false })
    $null = ipconfig /renew 2>&1
    $r['dhcp.renew'] = $LASTEXITCODE -eq 0
    [pscustomobject]$r
}

# UDP echo inside the VM, for the stateful check (the host speaks first, as Moonlight does).
# It lives in a background job of a session kept open for the whole lab.
$startEcho = {
    param($port)
    Get-NetFirewallRule -DisplayName 'GpuVM-Lab010' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName 'GpuVM-Lab010' -Direction Inbound -Protocol UDP -LocalPort $port -Action Allow | Out-Null
    $global:echo = Start-Job -ArgumentList $port -ScriptBlock {
        param($port)
        $u = [Net.Sockets.UdpClient]::new($port)
        $ep = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
        $deadline = (Get-Date).AddMinutes(10)
        while ((Get-Date) -lt $deadline) {
            if ($u.Available) { $d = $u.Receive([ref]$ep); $null = $u.Send($d, $d.Length, $ep) } else { Start-Sleep -Milliseconds 20 }
        }
    }
}
$stopEcho = {
    if ($global:echo) { $global:echo | Stop-Job -PassThru | Remove-Job -Force }
    Get-NetFirewallRule -DisplayName 'GpuVM-Lab010' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
}

function Test-HostSide {
    param($vmIp)
    $r = [ordered]@{}
    $times = foreach ($i in 1..20) {
        $c = [Net.Sockets.TcpClient]::new()
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try { if ($c.ConnectAsync($vmIp, 47990).Wait(1500) -and $c.Connected) { $sw.Elapsed.TotalMilliseconds } } catch {} finally { $c.Dispose() }
    }
    $sorted = @($times | Sort-Object)
    $r['vm.sunshine47990.connects'] = $sorted.Count
    $r['vm.sunshine47990.medianMs'] = if ($sorted.Count) { [math]::Round($sorted[[int]($sorted.Count / 2)], 3) } else { $null }
    $r['vm.sunshine47984'] = $sorted.Count -gt 0 -and $(try { $c = [Net.Sockets.TcpClient]::new(); $c.ConnectAsync($vmIp, 47984).Wait(1500) -and $c.Connected } catch { $false } finally { $c.Dispose() })
    $u = [Net.Sockets.UdpClient]::new()
    $u.Client.ReceiveTimeout = 1500
    try {
        $bytes = [Text.Encoding]::ASCII.GetBytes('gpuvm')
        $null = $u.Send($bytes, $bytes.Length, $vmIp, $echoPort)
        $ep = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
        $r['vm.udpEchoReply'] = [Text.Encoding]::ASCII.GetString($u.Receive([ref]$ep)) -eq 'gpuvm'
    }
    catch { $r['vm.udpEchoReply'] = $false }
    finally { $u.Dispose() }
    $r
}

function Invoke-Round {
    param([string]$Label)
    $inside = Invoke-Command -Session $session -ScriptBlock $guestProbe -ArgumentList $hostIp, $hostLl, $lanIp, $gateway, $listening, $labPort, $echoPort
    $inside = [ordered]@{} + ($inside.PSObject.Properties | Where-Object Name -notmatch '^(PS|RunspaceId)' | ForEach-Object -Begin { $h = [ordered]@{} } -Process { $h[$_.Name] = $_.Value } -End { $h })
    [ordered]@{ label = $Label; at = (Get-Date).ToString('o'); guest = $inside; host = Test-HostSide $endpoint.Address }
}

$candidateAcls = @(
    # From the VM to private networks, link-local, CGNAT and multicast: denied (lowest priority).
    foreach ($range in '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '100.64.0.0/10', '224.0.0.0/4', '::/0') {
        @{ Action = 'Deny'; Direction = 'Outbound'; RemoteIPAddress = $range }
    }
    # DHCP and DNS from the host's NAT (Default Switch).
    @{ Action = 'Allow'; Direction = 'Outbound'; RemoteIPAddress = $hostIp; Protocol = 'UDP'; RemotePort = '67' }
    @{ Action = 'Allow'; Direction = 'Outbound'; RemoteIPAddress = $hostIp; Protocol = 'UDP'; RemotePort = '53' }
    @{ Action = 'Allow'; Direction = 'Outbound'; RemoteIPAddress = $hostIp; Protocol = 'TCP'; RemotePort = '53' }
    # Moonlight on the host opens these; the replies are allowed by the flow it started (stateful).
    @{ Action = 'Allow'; Direction = 'Inbound'; RemoteIPAddress = $hostIp; Protocol = 'TCP'; LocalPort = '47984-48010'; Stateful = $true }
    @{ Action = 'Allow'; Direction = 'Inbound'; RemoteIPAddress = $hostIp; Protocol = 'UDP'; LocalPort = '47998-48010'; Stateful = $true }
)

$report = [ordered]@{ vm = $Name; switch = $switch; hostIp = $hostIp; lanIp = $lanIp; gateway = $gateway; listening = $listening; rounds = @() }
$session = New-PSSession -VMName $Name -Credential $guest
try {
    Invoke-Command -Session $session -ScriptBlock $startEcho -ArgumentList $echoPort
    if ($Installed) {
        $report['acls'] = @(Get-VMNetworkAdapterExtendedAcl -VMName $Name | Select-Object Direction, Action, RemoteIPAddress, RemotePort, LocalPort, Protocol, Stateful, Weight)
        $report.rounds += Invoke-Round 'gpuvm'
        return
    }
    $report.rounds += Invoke-Round 'baseline'

    $weight = $aclTag
    foreach ($acl in $candidateAcls) {
        $weight++
        Add-VMNetworkAdapterExtendedAcl -VMName $Name -Weight $weight @acl
    }
    $report['acls'] = @(Get-VMNetworkAdapterExtendedAcl -VMName $Name | Select-Object Direction, Action, RemoteIPAddress, RemotePort, LocalPort, Protocol, Stateful, Weight)
    $report.rounds += Invoke-Round 'candidate'
}
catch { $report['error'] = "$($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)" }
finally {
    if (-not $Installed) {
        Get-VMNetworkAdapterExtendedAcl -VMName $Name | Where-Object { $_.Weight -gt $aclTag -and $_.Weight -le $aclTag + 100 } | Remove-VMNetworkAdapterExtendedAcl
        try { $report.rounds += Invoke-Round 'reverted' }
        catch { $report['revertError'] = $_.Exception.Message }
    }
    try { Invoke-Command -Session $session -ScriptBlock $stopEcho; Remove-PSSession $session }
    catch { $report['cleanupError'] = $_.Exception.Message }
    $listener | Stop-Job -PassThru | Remove-Job -Force
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    if ($startedHere) { Stop-VM -Name $Name }
    New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
    $report | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 $OutFile
}
