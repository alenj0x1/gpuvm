# Lab 050: who can use the Hyper-V socket channel, and where a per-VM secret can live.
# Guest identities: system (SYSTEM, session 0), gpuvm (signed-in user, medium), agent (standard user on the same
# desktop), low (gpuvm with a low-integrity copy of the probe). For each: open AF_HYPERV, dial the host's registered
# service, bind/listen on a service GUID. Then: an unregistered GUID; squatting the guest-side service name (before and
# after a SYSTEM listener holds it, and whether the host's dial reaches the squatter); a secret in a host->guest KVP
# item versus a file pushed with Copy-VMFile into a SYSTEM/Administrators-only folder; and on the host, whether a
# non-elevated process can listen for the VMs on a registered GUID, and what happens when two processes try.
# Test VM only. Everything created is removed (user, folder, KVP item, GUIDs, Guest Service Interface back to its state).
# Run elevated: pwsh -File labs/050-access-control/run.ps1 -Name agentlab
param(
    [Parameter(Mandatory)][string]$Name,
    [string]$OutDir = (Join-Path $PSScriptRoot "out\run-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
)
$ErrorActionPreference = 'Stop'
if ($Name -eq 'win-gpu') { throw 'Test VM only.' }
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
. (Join-Path $root 'tools\latency\common.ps1')
. (Join-Path $root 'labs\048-capture\guest.ps1')
. (Join-Path $root 'labs\042-admin-dock\kvp-host.ps1')
New-Item -ItemType Directory -Force $OutDir | Out-Null
$hv = Join-Path $root 'labs\047-hvsocket\hvlab\target\release\hvlab.exe'
$svcReg = 'b1c0a047-6a5e-4c4b-9e47-047047047047'     # registered (lab 047)
$svcGuest = 'b1c0a050-6a5e-4c4b-9e47-050050050050'   # registered here: the guest-side listener's name
$svcUnreg = 'b1c0a050-dead-4c4b-9e47-050050050051'   # never registered
$labVm = Get-LatencyVM -Name $Name
$vmId = (Get-VM -Name $Name).Id.Guid
$sess = New-PSSession -VMName $Name -Credential $labVm.Guest
$results = [ordered]@{}
$pwFile = 'C:\GpuVMLab048\agent-pw.txt'
$agentPw = $null
$hostProcs = [System.Collections.Generic.List[object]]::new()
$gsiWasEnabled = (Get-VMIntegrationService -VMName $Name | Where-Object Id -like '*6C09BB55-D683-4DA0-8931-C9BF705F6480*').Enabled

function As([string]$who, [string[]]$probeArgs) {
    switch ($who) {
        'system' { $r = Invoke-GuestProbe -Session $sess -ProbeArgs $probeArgs -AsSystem }
        'gpuvm' { $r = Invoke-GuestProbe -Session $sess -ProbeArgs $probeArgs }
        'low' {
            $id = Start-GuestProbe -Session $sess -ProbeArgs ($probeArgs + @('--out', 'C:\GpuVMLab048\low\result.json')) -Exe 'C:\GpuVMLab048\low\agentprobe-low.exe'
            $null = Receive-GuestProbe -Session $sess -Id $id
            Start-Sleep -Seconds 2
            $r = Invoke-Command -Session $sess { $f = 'C:\GpuVMLab048\low\result.json'; [pscustomobject]@{ result = if (Test-Path $f) { Get-Content $f -Raw }; launch = $null }; Remove-Item $f -ErrorAction SilentlyContinue }
        }
        'agent' {
            Invoke-Command -Session $sess -ArgumentList $pwFile, $agentPw {
                param($f, $p)
                Set-Content $f $p -NoNewline
                icacls $f /inheritance:r /grant:r '*S-1-5-18:R' '*S-1-5-32-544:F' "$env:COMPUTERNAME\gpuvm:R" | Out-Null
            }
            try { $r = Invoke-GuestProbe -Session $sess -ProbeArgs (@('launch-as', '--user', 'agent', '--password-file', $pwFile, '--wait', '--') + $probeArgs) }
            finally { Invoke-Command -Session $sess -ArgumentList $pwFile { param($f) Remove-Item $f -Force -ErrorAction SilentlyContinue } }
        }
    }
    if ($r.result) { try { return $r.result | ConvertFrom-Json } catch { return $r.result } }
    "no result (launch: $($r.launch))"
}

function Start-HostListener([string]$svc, [string]$file, [switch]$Unelevated) {
    if ($Unelevated) {
        # The person's own medium token: an interactive, limited task of the signed-in host user.
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        $a = New-ScheduledTaskAction -Execute $hv -Argument "listen --bind children --service $svc --log `"$file`""
        Register-ScheduledTask -TaskName GpuVMLab050-hostlisten -Action $a -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
        Start-ScheduledTask GpuVMLab050-hostlisten
        Start-Sleep -Seconds 2
        Unregister-ScheduledTask GpuVMLab050-hostlisten -Confirm:$false
    } else {
        $hostProcs.Add((Start-Process $hv -ArgumentList 'listen', '--bind', 'children', '--service', $svc, '--log', $file -PassThru -WindowStyle Hidden))
        Start-Sleep -Milliseconds 800
    }
}

function Stop-HostListeners {
    Get-CimInstance Win32_Process -Filter "Name='hvlab.exe'" | Where-Object CommandLine -match 'listen' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

try {
    & (Join-Path $root 'labs\047-hvsocket\service.ps1') -Guid $svcReg
    & (Join-Path $root 'labs\047-hvsocket\service.ps1') -Guid $svcGuest -Name 'GpuVM lab 050 guest listener'
    Stop-HostListeners
    Install-GuestProbe -Session $sess
    Copy-Item $hv -ToSession $sess -Destination C:\GpuVMLab048\hvlab.exe -Force

    # identities: agent user, low-integrity copy
    $bytes = [byte[]]::new(18); [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $agentPw = 'Ag9!' + [Convert]::ToBase64String($bytes).Replace('/', 'x').Replace('+', 'y')
    Invoke-Command -Session $sess -ArgumentList $agentPw {
        param($p)
        if (-not (Get-LocalUser agent -ErrorAction SilentlyContinue)) {
            New-LocalUser -Name agent -Password (ConvertTo-SecureString $p -AsPlainText -Force) -AccountNeverExpires -PasswordNeverExpires -Description 'GpuVM lab 050' | Out-Null
        } else { Set-LocalUser -Name agent -Password (ConvertTo-SecureString $p -AsPlainText -Force) }
        Add-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-545').Name -Member agent -ErrorAction SilentlyContinue
        icacls C:\GpuVMLab048 /grant '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
        New-Item -ItemType Directory -Force C:\GpuVMLab048\low | Out-Null
        Copy-Item C:\GpuVMLab048\agentprobe.exe C:\GpuVMLab048\low\agentprobe-low.exe
        icacls C:\GpuVMLab048\low\agentprobe-low.exe /setintegritylevel low | Out-Null
        icacls C:\GpuVMLab048\low /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
        icacls C:\GpuVMLab048\low /setintegritylevel '(OI)(CI)low' | Out-Null
    }
    $ids = 'system', 'gpuvm', 'agent', 'low'
    $results.whoami = [ordered]@{}
    foreach ($who in $ids) { $results.whoami[$who] = As $who @('whoami'); "$who : $($results.whoami[$who] | ConvertTo-Json -Compress)" }

    # 1. Dial the host's registered service and bind a guest-side name, per identity
    $hostLog = Join-Path $OutDir 'host-listener.jsonl'
    Start-HostListener $svcReg $hostLog
    $results.channel = [ordered]@{}
    foreach ($who in $ids) {
        $results.channel[$who] = As $who @('hv', '--service', $svcReg, '--bind-service', $svcGuest)
        "$who channel: $($results.channel[$who] | ConvertTo-Json -Compress)"
    }
    $results.hostSawPeers = @(Get-Content $hostLog | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object ev -eq 'accept' | ForEach-Object { $_.peerVm }) | Group-Object | ForEach-Object { [pscustomobject]@{ peerVm = $_.Name; count = $_.Count; matchesVm = ($_.Name -eq $vmId) } }
    "host saw: $($results.hostSawPeers | ConvertTo-Json -Compress)"

    # 2. Unregistered service GUID (guest dial)
    $results.unregisteredDial = As 'gpuvm' @('hv', '--service', $svcUnreg, '--bind-service', $svcUnreg)
    "unregistered: $($results.unregisteredDial | ConvertTo-Json -Compress)"

    # 3. Squatting the guest-side name
    #  a) SYSTEM listener holds it first, agent tries to bind the same name
    Invoke-Command -Session $sess -ArgumentList $svcGuest {
        param($svc)
        $a = New-ScheduledTaskAction -Execute C:\GpuVMLab048\hvlab.exe -Argument "listen --bind wildcard --service $svc --log C:\GpuVMLab048\out\sys-listener.jsonl"
        Register-ScheduledTask -TaskName GpuVMLab048-syslisten -Action $a -Principal (New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest) -Force | Out-Null
        Start-ScheduledTask GpuVMLab048-syslisten
        Start-Sleep -Seconds 1
    }
    $results.squatAfterSystem = As 'agent' @('hv', '--service', $svcReg, '--bind-service', $svcGuest)
    $results.hostDialWhileSystemListens = & $hv once --vm $vmId --service $svcGuest | ConvertFrom-Json
    Invoke-Command -Session $sess { Get-Process hvlab -ErrorAction SilentlyContinue | Stop-Process -Force; Unregister-ScheduledTask GpuVMLab048-syslisten -Confirm:$false }
    "squat after SYSTEM: $($results.squatAfterSystem | ConvertTo-Json -Compress); host dial: $($results.hostDialWhileSystemListens | ConvertTo-Json -Compress)"
    #  b) nobody holds it: agent binds and waits; the host dials the VM on that name
    Invoke-Command -Session $sess -ArgumentList $pwFile, $agentPw { param($f, $p) Set-Content $f $p -NoNewline; icacls $f /inheritance:r /grant:r '*S-1-5-18:R' '*S-1-5-32-544:F' "$env:COMPUTERNAME\gpuvm:R" | Out-Null }
    $id = Start-GuestProbe -Session $sess -ProbeArgs @('launch-as', '--user', 'agent', '--password-file', $pwFile, '--wait', '--', 'hv', '--service', $svcReg, '--bind-service', $svcGuest, '--hold-ms', '10000') -TimeoutSec 60
    Start-Sleep -Seconds 5
    Invoke-Command -Session $sess -ArgumentList $pwFile { param($f) Remove-Item $f -Force -ErrorAction SilentlyContinue }
    $results.hostDialReachesSquatter = & $hv once --vm $vmId --service $svcGuest --timeout 3000 | ConvertFrom-Json
    $sq = Receive-GuestProbe -Session $sess -Id $id -TimeoutSec 60
    $results.squatterView = if ($sq.result) { $sq.result | ConvertFrom-Json } else { "launch: $($sq.launch)" }
    "squatter: $($results.squatterView | ConvertTo-Json -Compress); host dial: $($results.hostDialReachesSquatter | ConvertTo-Json -Compress)"

    # 4. A secret in a host -> guest KVP item
    $secret = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
    Set-HostKvpItem -VMName $Name -Key GpuVMLab050Secret -Value $secret -Add
    Start-Sleep -Seconds 2
    $results.kvpRead = [ordered]@{}
    foreach ($who in $ids) { $results.kvpRead[$who] = As $who @('regread', '--value', 'GpuVMLab050Secret') }
    $results.kvpAcl = Invoke-Command -Session $sess { (Get-Acl 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\External').Access | ForEach-Object { "$($_.IdentityReference): $($_.RegistryRights) $($_.AccessControlType)" } }
    "kvp read: $($results.kvpRead | ConvertTo-Json -Compress)"

    # 5. A secret file pushed with Copy-VMFile into a SYSTEM/Administrators-only folder
    if (-not $gsiWasEnabled) { Enable-VMIntegrationService -VMName $Name -Name (Get-VMIntegrationService -VMName $Name | Where-Object Id -like '*6C09BB55-D683-4DA0-8931-C9BF705F6480*').Name }
    Invoke-Command -Session $sess {
        $d = 'C:\ProgramData\GpuVMLab050'
        New-Item -ItemType Directory -Force $d | Out-Null
        icacls $d /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    }
    $tmp = Join-Path $OutDir 'secret.bin'
    [IO.File]::WriteAllBytes($tmp, [Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    Start-Sleep -Seconds 3
    $copyMs = (Measure-Command { Copy-VMFile -VMName $Name -FileSource Host -SourcePath $tmp -DestinationPath 'C:\ProgramData\GpuVMLab050\secret.bin' -Force }).TotalMilliseconds
    Remove-Item $tmp
    $results.copyVMFileMs = [math]::Round($copyMs)
    $results.copyVMFileAcl = Invoke-Command -Session $sess { $a = Get-Acl C:\ProgramData\GpuVMLab050\secret.bin; [pscustomobject]@{ owner = $a.Owner; access = @($a.Access | ForEach-Object { "$($_.IdentityReference): $($_.FileSystemRights) $($_.AccessControlType) inherited=$($_.IsInherited)" }) } }
    $results.fileRead = [ordered]@{}
    foreach ($who in $ids) { $results.fileRead[$who] = As $who @('read', '--path', 'C:\ProgramData\GpuVMLab050\secret.bin') }
    "file read: $($results.fileRead | ConvertTo-Json -Compress)"

    # 6. Host: a non-elevated listener, and two listeners on one name
    Stop-HostListeners
    $u = Join-Path $OutDir 'host-unelevated.jsonl'
    Start-HostListener $svcReg $u -Unelevated
    Start-Sleep -Seconds 1
    $results.hostUnelevatedListen = @(Get-Content $u -ErrorAction SilentlyContinue)
    $results.guestDialToUnelevated = As 'gpuvm' @('hv', '--service', $svcReg, '--bind-service', $svcUnreg)
    $second = Join-Path $OutDir 'host-second.jsonl'
    Start-HostListener $svcReg $second
    $results.hostSecondListener = @(Get-Content $second -ErrorAction SilentlyContinue)
    Stop-HostListeners
    $unreg = Join-Path $OutDir 'host-unregistered.jsonl'
    Start-HostListener $svcUnreg $unreg
    $results.hostListenUnregistered = @(Get-Content $unreg -ErrorAction SilentlyContinue)
    $results.guestDialUnregisteredWithListener = As 'gpuvm' @('hv', '--service', $svcUnreg, '--bind-service', $svcUnreg)
    Stop-HostListeners
    "host unelevated: $($results.hostUnelevatedListen -join ' | ')"
    "guest -> unelevated host listener: $($results.guestDialToUnelevated | ConvertTo-Json -Compress)"
    "host second listener: $($results.hostSecondListener -join ' | ')"
    "host unregistered: $($results.hostListenUnregistered -join ' | '); guest dial: $($results.guestDialUnregisteredWithListener | ConvertTo-Json -Compress)"
}
finally {
    $results | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $OutDir 'results.json')
    Stop-HostListeners
    try { Remove-HostKvpItem -VMName $Name -Key GpuVMLab050Secret } catch {}
    try {
        Invoke-Command -Session $sess {
            Get-Process hvlab, agentprobe, agentprobe-low -ErrorAction SilentlyContinue | Stop-Process -Force
            Get-ScheduledTask -TaskName 'GpuVMLab048-*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
            Get-CimInstance Win32_Process | Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue).User -eq 'agent' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 1
            Remove-LocalUser agent -ErrorAction SilentlyContinue
            Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -like '*\agent' } | Remove-CimInstance -ErrorAction SilentlyContinue
            Remove-Item C:\ProgramData\GpuVMLab050 -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-GuestProbe -Session $sess
    } catch { Write-Warning "guest cleanup: $_" }
    if (-not $gsiWasEnabled) { Disable-VMIntegrationService -VMName $Name -Name (Get-VMIntegrationService -VMName $Name | Where-Object Id -like '*6C09BB55-D683-4DA0-8931-C9BF705F6480*').Name -ErrorAction SilentlyContinue }
    & (Join-Path $root 'labs\047-hvsocket\service.ps1') -Guid $svcGuest -Remove
    Remove-PSSession $sess -ErrorAction SilentlyContinue
    "out: $OutDir"
}
