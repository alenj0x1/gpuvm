# Quick read-only diagnosis of the stream path: Sunshine inside the VM, the VM's port ACLs and TCP from the host.
param(
    [string]$Name = (Get-VM | Where-Object Notes -like "Creada con GpuVM*" | Select-Object -First 1).Name,
    [string]$OutFile = (Join-Path $PSScriptRoot "out\diag-$(Get-Date -Format yyyyMMdd-HHmmss).json")
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$module = Get-Module GpuVM
$report = [ordered]@{}
try {
    $state = & $module { param($n) Get-GpuVMState -Name $n } $Name
    $guest = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state
    $report['hostVEthernet'] = @(Get-NetIPAddress -InterfaceAlias 'vEthernet (Default Switch)' -AddressFamily IPv4 | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
    $report['vmIps'] = @((Get-VMNetworkAdapter -VMName $Name).IPAddresses)
    $report['acls'] = @(Get-VMNetworkAdapterExtendedAcl -VMName $Name | Sort-Object Weight -Descending | ForEach-Object { "$($_.Weight) $($_.Direction) $($_.Action) $($_.RemoteIPAddress) $($_.Protocol) l=$($_.LocalPort) r=$($_.RemotePort) st=$($_.Stateful)" })
    $report['guest'] = Invoke-Command -VMName $Name -Credential $guest -ScriptBlock {
        [pscustomobject]@{
            services  = @(Get-Service | Where-Object Name -like '*sunshine*' | ForEach-Object { "$($_.Name) $($_.Status) $($_.StartType)" })
            processes = @(Get-CimInstance Win32_Process | Where-Object Name -like '*sunshine*' | ForEach-Object { "$($_.Name) pid $($_.ProcessId) session $($_.SessionId) $($_.CommandLine)" })
            listening = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -in 47984, 47989, 47990, 48010 | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort) pid $($_.OwningProcess)" })
            ips       = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -notlike '127.*' | ForEach-Object { "$($_.InterfaceAlias) $($_.IPAddress)/$($_.PrefixLength)" })
            log       = @(Get-Content 'C:\Program Files\Sunshine\config\sunshine.log' -Tail 25 -ErrorAction SilentlyContinue)
            selfTest  = $(try { $c = [Net.Sockets.TcpClient]::new(); $ok = $c.ConnectAsync('127.0.0.1', 47990).Wait(2000) -and $c.Connected; $c.Dispose(); $ok } catch { $false })
        }
    } | Select-Object services, processes, listening, ips, log, selfTest
    $vmIp = ($report['vmIps'] | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' } | Select-Object -First 1)
    $report['hostToVm'] = [ordered]@{}
    foreach ($port in 47984, 47989, 47990, 48010) {
        $c = [Net.Sockets.TcpClient]::new()
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $result = try { if ($c.ConnectAsync($vmIp, $port).Wait(3000) -and $c.Connected) { 'open' } else { 'timeout' } } catch { "error: $($_.Exception.InnerException.Message)" } finally { $c.Dispose() }
        $report['hostToVm']["$port"] = "$result $([int]$sw.ElapsedMilliseconds) ms"
    }
}
catch { $report['error'] = "$($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)" }
finally {
    New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
    $report | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 $OutFile
}
