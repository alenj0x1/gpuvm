# Lab 052: why a copy of agent-tpl stays at "Waiting for Sunshine". Makes a copy (3 GB in Hyper-V only), starts it
# and looks at both ends: the host (the address GpuVM has, the Sunshine web port, the API with the saved credential,
# the network isolation rules) and the guest (Sunshine's service, ports, firewall, log, identity, displays). Nothing
# installed is touched; the copy is deleted at the end. Under the shared lab lock. Run elevated.
param([string]$Template = 'agent-tpl', [string]$Name = 'agent052s', [string]$Session = 'agent-broker', [int]$WaitSec = 240)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$r = [ordered]@{}
function Line($what) { Write-Host "$(Get-Date -Format HH:mm:ss) $what" }
& (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What "lab 052: Sunshine on a copy of $Template" -Me $Session -MaxMinutes 180
if ($LASTEXITCODE) { throw 'no lock' }
$made = $false
try {
    Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
    $m = Get-Module GpuVM
    New-GpuVM -Name $Name -Template $Template | Out-Null
    $made = $true
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes 3GB
    Start-VM -Name $Name
    $state = & $m { param($n) Get-GpuVMState -Name $n } $Name
    $r['stateUse'] = $state['use']
    $r['stateStreamingKeys'] = @($state['streaming'].Keys)
    $r['isolation'] = & $m { param($s) Get-GpuVMNetworkIsolation -State $s } $state
    $cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
    $sun = & $m { param($s) Get-SunshineCredential -State $s } $state
    $w = [Diagnostics.Stopwatch]::StartNew()
    while ($w.Elapsed.TotalMinutes -lt 10) { try { Invoke-Command -VMName $Name -Credential $cred { 1 } -ErrorAction Stop | Out-Null; break } catch { Start-Sleep -Milliseconds 500 } }
    $r['psDirectMs'] = [math]::Round($w.Elapsed.TotalMilliseconds)
    # What Connect-GpuVM does first: the address, then Sunshine's API with the saved credential.
    $w.Restart()
    $address = & $m { param($n) Get-GpuVMAddress -Name $n -TimeoutSec 180 } $Name
    $r['address'] = $address
    $r['addressMs'] = [math]::Round($w.Elapsed.TotalMilliseconds)
    $r['vmIPs'] = @((Get-VMNetworkAdapter -VMName $Name).IPAddresses)
    $r['aclRules'] = @(Get-VMNetworkAdapterExtendedAcl -VMName $Name).Count
    $apiError = $null
    $w.Restart()
    while ($w.Elapsed.TotalSeconds -lt $WaitSec) {
        try { & $m { param($a, $c) Invoke-SunshineApi -Address $a -Credential $c -Path '/api/clients/list' } $address $sun | Out-Null; $apiError = $null; break }
        catch { $apiError = "$($_.Exception.Message)"; Start-Sleep -Seconds 3 }
    }
    $r['sunshineApiMs'] = [math]::Round($w.Elapsed.TotalMilliseconds)
    $r['sunshineApiError'] = $apiError
    $r['tcp47990FromHost'] = (Test-NetConnection -ComputerName $address -Port 47990 -WarningAction SilentlyContinue).TcpTestSucceeded
    $r['tcp47989FromHost'] = (Test-NetConnection -ComputerName $address -Port 47989 -WarningAction SilentlyContinue).TcpTestSucceeded
    Line "address $address; API: $(if ($apiError) { $apiError } else { 'ok' }); tcp 47990 $($r['tcp47990FromHost']), 47989 $($r['tcp47989FromHost']); ACL rules $($r['aclRules'])"
    $r['guest'] = Invoke-Command -VMName $Name -Credential $cred {
        $cfg = 'C:\Program Files\Sunshine\config'
        $log = Join-Path $cfg 'sunshine.log'
        $svc = Get-Service SunshineService -ErrorAction SilentlyContinue
        $proc = Get-Process sunshine -ErrorAction SilentlyContinue
        [ordered]@{
            service = if ($svc) { "$($svc.Status)" } else { 'missing' }
            process = [bool]$proc
            listening = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 47984, 47989, 47990, 48010 } | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)" })
            firewall = @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Sunshine' } | ForEach-Object { "$($_.DisplayName) $($_.Enabled) $($_.Direction) $($_.Action)" })
            ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object IPAddress)
            credentialsDir = @(Get-ChildItem (Join-Path $cfg 'credentials') -ErrorAction SilentlyContinue | ForEach-Object Name)
            stateJson = if (Test-Path (Join-Path $cfg 'sunshine_state.json')) { (Get-Content -Raw (Join-Path $cfg 'sunshine_state.json')).Length } else { $null }
            logTail = if (Test-Path $log) { @(Get-Content $log -Tail 40) } else { @('no log') }
            displays = @(Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name): $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution) $($_.Status)" })
            consoleUser = (Get-CimInstance Win32_ComputerSystem).UserName
            setupDone = Test-Path 'C:\GpuVM\setup.done.json'
        }
    }
    Line "guest: service $($r['guest'].service), listening $($r['guest'].listening -join ','), credentials $($r['guest'].credentialsDir -join ','), console $($r['guest'].consoleUser)"
    $r['guest'].logTail | Select-Object -Last 15 | ForEach-Object { Line "sunshine.log: $_" }
}
finally {
    if ($made) {
        try { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false; Line "$Name deleted" }
        catch { Line "couldn't delete $Name : $($_.Exception.Message)" }
    }
    $r | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out "sunshine-clone-$stamp.json") -Encoding utf8
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Line 'lock released'
}
