# Lab 047 part B: hvsocket across guest reboot, VM turn-off/on and clean shutdown/start (Save-VM is refused with GPU-P). Guest side runs as boot-time SYSTEM
# tasks (stand-in for the future service): `hvlab watch` dials the parent every 200 ms and keeps a connection; `hvlab
# listen` answers host dials. Host side: a listener on HV_GUID_CHILDREN and a watcher dialing the VM. Every event is
# a JSON line with a Unix ms timestamp; the script adds its own action marks. Then: how long until each side is
# connected again after power-on, versus when PowerShell Direct starts answering.
# Only for a disposable test VM. Run elevated: pwsh -File labs/047-hvsocket/reboot.ps1 -Name agentlab
param(
    [Parameter(Mandatory)][string]$Name,
    [int]$Cycles = 2,
    [string]$Service = 'b1c0a047-6a5e-4c4b-9e47-047047047047',
    [string]$OutDir = (Join-Path $PSScriptRoot "out\reboot-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
)
$ErrorActionPreference = 'Stop'
if ($Name -eq 'win-gpu') { throw 'Reboot tests run on a test VM only.' }
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
. (Join-Path $root 'tools\latency\common.ps1')
New-Item -ItemType Directory -Force $OutDir | Out-Null
$exe = Join-Path $PSScriptRoot 'hvlab\target\release\hvlab.exe'
& (Join-Path $PSScriptRoot 'service.ps1') -Guid $Service
$vmId = (Get-VM -Name $Name).Id.Guid
$cred = (Get-LatencyVM -Name $Name).Guest
$marks = Join-Path $OutDir 'marks.jsonl'
function Mark([string]$what) {
    $line = @{ ev = 'mark'; what = $what; t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() } | ConvertTo-Json -Compress
    Add-Content $marks $line; "$(Get-Date -Format HH:mm:ss.fff) $what"
}
function Wait-PSDirect([int]$timeoutSec = 300) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        if ((Get-VM -Name $Name).State -ne 'Running') { throw "VM $Name is not running" }
        try { $null = Invoke-Command -VMName $Name -Credential $cred { 1 } -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 500 }
    }
    throw 'PowerShell Direct never answered'
}
function Wait-HostLog([string]$file, [string]$ev, [long]$after, [int]$timeoutSec = 300) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        if (Test-Path $file) {
            $hit = Get-Content $file | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.ev -eq $ev -and $_.t -gt $after } | Select-Object -First 1
            if ($hit) { return $hit }
        }
        Start-Sleep -Milliseconds 200
    }
    $null
}

$hostListen = Join-Path $OutDir 'host-listener.jsonl'
$hostWatch = Join-Path $OutDir 'host-watch.jsonl'
$pl = $pw = $null
try {
    $sess = New-PSSession -VMName $Name -Credential $cred
    Invoke-Command -Session $sess { New-Item -ItemType Directory -Force C:\GpuVMLab047 | Out-Null }
    Copy-Item $exe -ToSession $sess -Destination C:\GpuVMLab047\hvlab.exe -Force
    Invoke-Command -Session $sess -ArgumentList $Service {
        param($svc)
        $p = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
        $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        $t = New-ScheduledTaskTrigger -AtStartup
        $a1 = New-ScheduledTaskAction -Execute C:\GpuVMLab047\hvlab.exe -Argument "watch --vm parent --service $svc --seconds 86400 --interval 200 --log C:\GpuVMLab047\guest-watch.jsonl"
        $a2 = New-ScheduledTaskAction -Execute C:\GpuVMLab047\hvlab.exe -Argument "listen --bind wildcard --service $svc --log C:\GpuVMLab047\guest-listener.jsonl"
        Register-ScheduledTask -TaskName GpuVMLab047-watch -Action $a1 -Principal $p -Settings $s -Trigger $t -Force | Out-Null
        Register-ScheduledTask -TaskName GpuVMLab047-listen -Action $a2 -Principal $p -Settings $s -Trigger $t -Force | Out-Null
        Start-ScheduledTask GpuVMLab047-watch; Start-ScheduledTask GpuVMLab047-listen
    }
    Remove-PSSession $sess
    $pl = Start-Process $exe -ArgumentList 'listen', '--bind', 'children', '--service', $Service, '--log', $hostListen -PassThru -WindowStyle Hidden
    $pw = Start-Process $exe -ArgumentList 'watch', '--vm', $vmId, '--service', $Service, '--seconds', '86400', '--interval', '200', '--log', $hostWatch -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 3

    $results = [System.Collections.Generic.List[object]]::new()
    for ($c = 1; $c -le $Cycles; $c++) {
        foreach ($kind in 'guest-restart', 'turnoff-start', 'shutdown-start') {
            Start-Sleep -Seconds (Get-Random -Minimum 3 -Maximum 8)
            $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            Mark "$kind begin (cycle $c)"
            switch ($kind) {
                'guest-restart' { Invoke-Command -VMName $Name -Credential $cred { Restart-Computer -Force } }
                'turnoff-start' { Stop-VM -Name $Name -TurnOff -Force; Mark 'off'; Start-VM -Name $Name }
                # Save-VM is refused for VMs with a GPU-P partition (lab 047), so a clean shutdown instead
                'shutdown-start' { Stop-VM -Name $Name -Force; Mark 'shut down'; Start-VM -Name $Name }
            }
            $tOn = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            Mark "$kind start issued"
            $broken = Wait-HostLog $hostWatch 'broken' $t0 30
            $acc = Wait-HostLog $hostListen 'accept' $tOn 300
            $reconn = Wait-HostLog $hostWatch 'connected' $tOn 300
            $psStart = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            Wait-PSDirect
            $psOk = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $r = [pscustomobject]@{
                cycle = $c; kind = $kind
                hostWatchBrokenAfterMs = if ($broken) { $broken.t - $t0 } else { $null }
                hostWatchBrokenErr = if ($broken) { $broken.err } else { $null }
                guestDialedHostAfterStartMs = if ($acc) { $acc.t - $tOn } else { $null }
                guestDialPeerVm = if ($acc) { $acc.peerVm } else { $null }
                hostDialedGuestAfterStartMs = if ($reconn) { $reconn.t - $tOn } else { $null }
                psDirectOkAfterStartMs = $psOk - $tOn
                psDirectCheckStartedAfterMs = $psStart - $tOn
            }
            $results.Add($r)
            $r | Format-List | Out-String
        }
    }
    $results | ConvertTo-Json | Set-Content (Join-Path $OutDir 'results.json')
}
finally {
    foreach ($p in $pl, $pw) { if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
    try {
        $s2 = New-PSSession -VMName $Name -Credential $cred
        $gl = Invoke-Command -Session $s2 {
            Get-ScheduledTask -TaskName 'GpuVMLab047-*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
            Get-Process hvlab -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep -Milliseconds 300
            [pscustomobject]@{ watch = Get-Content C:\GpuVMLab047\guest-watch.jsonl -ErrorAction SilentlyContinue; listen = Get-Content C:\GpuVMLab047\guest-listener.jsonl -ErrorAction SilentlyContinue }
            Remove-Item C:\GpuVMLab047 -Recurse -Force -ErrorAction SilentlyContinue
        }
        Set-Content (Join-Path $OutDir 'guest-watch.jsonl') $gl.watch
        Set-Content (Join-Path $OutDir 'guest-listener.jsonl') $gl.listen
        Remove-PSSession $s2
    } catch { Write-Warning "guest cleanup: $_" }
    "out: $OutDir"
}
