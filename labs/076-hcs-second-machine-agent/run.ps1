# Lab 076: with two isolated HCS machines started one after the other, the second one's agent answered only after
# ~125 s in lab 074 (4 s alone). Times each sys.info call and keeps both machines' agent logs (connect, network).
#   pwsh -NoProfile -File labs/076-hcs-second-machine-agent/run.ps1 [-Order ab|ba] [-Isolated true|false]
param([string]$Template = 'normal-tpl', [ValidateSet('ab', 'ba')][string]$Order = 'ab', [ValidateSet('true', 'false')][string]$Isolated = 'true', [switch]$Serial, [ValidateSet('default', 'none', 'nvidia')][string]$Gpu = 'default',
    [string]$Exe = (Join-Path $PSScriptRoot '..\..\app\host\target\debug\gpuvm-host.exe'),
    [string]$Agent = (Join-Path $PSScriptRoot '..\..\guest\agent\dist\gpuvm-agent.exe'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = $PSScriptRoot
$root = 'C:\GpuVM\.lab076'; $lock = 'C:\GpuVM\.lab-lock'; $task = 'GpuVMLab076Broker'
$names = @('m076a', 'm076b'); if ($Order -eq 'ba') { [array]::Reverse($names) }
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $here 'out'; $null = New-Item -ItemType Directory -Force $outDir
$res = [ordered]@{ runId = $runId; order = $names; isolated = $Isolated; serial = [bool]$Serial; gpu = $Gpu; calls = [ordered]@{} }
$sw = [Diagnostics.Stopwatch]::StartNew()
function Write-Log([string]$m) { Write-Host ("[{0,6:n1}s] {1}" -f $sw.Elapsed.TotalSeconds, $m) }
function Invoke-Hc([string[]]$A) { $o = (& $Exe hcs @A | Select-Object -Last 1) | ConvertFrom-Json; if (-not $o.ok) { throw "hcs $($A[0]): $($o.error)" }; $o.result }

$Exe = (Resolve-Path $Exe).Path; $Agent = (Resolve-Path $Agent).Path
$tplDir = "C:\GpuVM\.templates\$Template"
$layer = Join-Path $tplDir ((Get-Content (Join-Path $tplDir 'template.json') -Raw | ConvertFrom-Json).layers[-1])
try { $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) }
catch [IO.IOException] { throw "The lab lock is held: $(Get-Content $lock -Raw)" }
$fs.Write([Text.Encoding]::UTF8.GetBytes("lab076 pid=$PID $(Get-Date -Format o)")); $fs.Close()
$wasRunning = (Get-Service GpuVM -ErrorAction SilentlyContinue).Status -eq 'Running'
try {
    if ($wasRunning) { Stop-Service GpuVM -Force; Start-Sleep 2 }
    & schtasks.exe /create /tn $task /tr "`"$Exe`" broker" /sc once /st 00:00 /ru SYSTEM /rl HIGHEST /f 2>$null | Out-Null
    & schtasks.exe /run /tn $task | Out-Null
    Start-Sleep 3
    foreach ($n in $names) {
        $null = Invoke-Hc @('create', $root, $n, $layer, '2048', '2')
        $null = Invoke-Hc @('install-agent', $root, $n, $Agent)
        $null = Invoke-Hc @('set', $root, $n, '--isolated', $Isolated, '--gpu', $Gpu)
    }
    $t0 = @{}
    foreach ($n in $names) {
        # -Serial: the second machine starts once the first one's agent answers, as the module's GPU power lock does.
        if ($Serial -and $t0.Count) { while (-not ((& $Exe hcs ask $names[0] sys.info '{}' | Select-Object -Last 1) | ConvertFrom-Json).result.ok) { Start-Sleep 1 } }
        $null = Invoke-Hc @('start', $root, $n); $t0[$n] = $sw.Elapsed.TotalSeconds; Write-Log "started $n"
    }
    $up = @{}
    while ($up.Count -lt 2 -and $sw.Elapsed.TotalSeconds -lt 400) {
        foreach ($n in $names) {
            if ($up.ContainsKey($n)) { continue }
            $c = [Diagnostics.Stopwatch]::StartNew()
            $o = (& $Exe hcs ask $n sys.info '{}' --timeout 20 | Select-Object -Last 1) | ConvertFrom-Json
            $ok = $o.ok -and $o.result.ok
            $err = if ($ok) { '' } elseif ($o.ok) { "$($o.result.error.code): $($o.result.error.message)" } else { "$($o.error)" }
            if (-not $res.calls.Contains($n)) { $res.calls[$n] = [Collections.Generic.List[string]]::new() }
            $res.calls[$n].Add(("{0:n1}s took {1:n1}s {2}" -f ($sw.Elapsed.TotalSeconds - $t0[$n]), $c.Elapsed.TotalSeconds, $(if ($ok) { 'ok' } else { $err })))
            if ($ok) { $up[$n] = [math]::Round($sw.Elapsed.TotalSeconds - $t0[$n], 1); Write-Log "$n agent after $($up[$n]) s" }
        }
        Start-Sleep 1
    }
    $res.agentSec = $up
    # The firmware's boot order and the last boot's firmware time, as Windows sees them.
    foreach ($n in $names) {
        $r = ((& $Exe hcs ask $n sys.exec '{"file":"bcdedit.exe","args":["/enum","firmware"]}' | Select-Object -Last 1) | ConvertFrom-Json).result.result
        $res["firmware-$n"] = if ($r) { "$($r.stdout)" } else { 'no answer' }
        $ps = @{ file = 'WindowsPowerShell\v1.0\powershell.exe'; args = @('-NoProfile', '-Command', "(Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Kernel-Boot';Id=27} -MaxEvents 1 -ErrorAction SilentlyContinue).Message; (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).FwPOSTTime") } | ConvertTo-Json -Compress
        $r = ((& $Exe hcs ask $n sys.exec $ps | Select-Object -Last 1) | ConvertFrom-Json).result.result
        $res["boot-$n"] = if ($r) { "$($r.stdout)".Trim() } else { 'no answer' }
    }
    # Turn the first machine off and on again at once, then after a pause: does a quick restart pay the delay?
    foreach ($pause in 0, 150) {
        $n = $names[0]
        # Let the guest finish what it does right after boot (the relay adapter installs then): pulling the plug in
        # the middle left Windows repairing itself on the next start.
        Start-Sleep 45
        # Windows shuts down as GpuVM does it by default (two pulled plugs in a row send Windows to Automatic Repair).
        $null = & $Exe hcs ask $n sys.power '{"action":"shutdown"}'
        $t = [Diagnostics.Stopwatch]::StartNew()
        while ((Invoke-Hc @('state', $root, $n)).state -in 'Running', 'Paused' -and $t.Elapsed.TotalSeconds -lt 90) { Start-Sleep 2 }
        $res["shutdownSec$pause"] = [math]::Round($t.Elapsed.TotalSeconds, 1)
        $null = Invoke-Hc @('off', $root, $n)
        Start-Sleep $pause
        $null = Invoke-Hc @('start', $root, $n); $t = [Diagnostics.Stopwatch]::StartNew()
        while (-not ((& $Exe hcs ask $n sys.info '{}' | Select-Object -Last 1) | ConvertFrom-Json).result.ok -and $t.Elapsed.TotalSeconds -lt 300) { Start-Sleep 1 }
        $res["restartAfter${pause}s"] = [math]::Round($t.Elapsed.TotalSeconds, 1)
        # Where the time went: the guest's boot moment against the host's start, and the firmware's own POST time.
        $startedAt = (Get-Date).AddSeconds(-$t.Elapsed.TotalSeconds)
        $ps = @{ file = 'WindowsPowerShell\v1.0\powershell.exe'; args = @('-NoProfile', '-Command', "'{0:o}|{1}' -f (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime(), (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power').FwPOSTTime") } | ConvertTo-Json -Compress
        $r = ((& $Exe hcs ask $n sys.exec $ps | Select-Object -Last 1) | ConvertFrom-Json).result.result
        if ($r) {
            $boot, $post = "$($r.stdout)".Trim() -split '\|'
            $res["bootDetail${pause}s"] = [ordered]@{ windowsBootAfterStartSec = [math]::Round(([datetime]$boot - $startedAt.ToUniversalTime()).TotalSeconds, 1); fwPostMs = $post }
            Write-Log "  $($res["bootDetail${pause}s"] | ConvertTo-Json -Compress)"
        }
        Write-Log "$n back after $($res["restartAfter${pause}s"]) s (off for $pause s)"
    }
} catch { $res.error = "$_"; Write-Log "FAILED: $_" }
finally {
    foreach ($n in $names) {
        $res["log-$n"] = @(Get-Content (Join-Path $root "$n\agent.log") -ErrorAction SilentlyContinue)
        $guestLog = Join-Path $outDir "$runId-$n-guest-agent.log"
        $null = & $Exe hcs ask $n sys.read (@{ path = 'C:\ProgramData\GpuVM\Agent\logs\agent.log' } | ConvertTo-Json -Compress) --out $guestLog
        try { $null = Invoke-Hc @('off', $root, $n) } catch { }
        try { $null = Invoke-Hc @('delete', $root, $n) } catch { }
    }
    try { $null = Invoke-Hc @('network-delete') } catch { }
    & schtasks.exe /end /tn $task 2>$null | Out-Null
    Get-CimInstance Win32_Process -Filter "Name='gpuvm-host.exe'" | Where-Object ExecutablePath -eq $Exe | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    & schtasks.exe /delete /tn $task /f 2>$null | Out-Null
    if ($wasRunning) { Start-Service GpuVM }
    if (@(& hcsdiag list 2>$null | Select-String 'gpuvm-m076').Count -eq 0) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    $res.totalSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $res | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $outDir "$runId.json")
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
    Write-Log "done -> out/$runId.json; left behind: root=$(Test-Path $root) systems=$(@(& hcsdiag list 2>$null | Select-String 'gpuvm-m076').Count) service=$((Get-Service GpuVM).Status)"
}
