# Lab 069: an HCS machine through GpuVM's own module commands (the same calls the app makes): New-GpuVM from a
# template with the hcs backend, Get-GpuVM, power, guest commands (Invoke-Guest through the agent), readiness, address,
# and Remove-GpuVM. Runs against this branch's host broker (the installed GpuVM service is stopped for the run and
# started again). -Connect also opens the stream in GpuVM's viewer for a few seconds.
#   pwsh -NoProfile -File labs/069-hcs-module/run.ps1 [-Connect]
param([string]$Template = 'normal-tpl', [switch]$Connect,
    [string]$Exe = (Join-Path $PSScriptRoot '..\..\app\host\target\debug\gpuvm-host.exe'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = $PSScriptRoot
$name = 'm069'; $lock = 'C:\GpuVM\.lab-lock'; $task = 'GpuVMLab069Broker'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $here 'out'; $null = New-Item -ItemType Directory -Force $outDir
$res = [ordered]@{ runId = $runId; steps = [ordered]@{} }
$sw = [Diagnostics.Stopwatch]::StartNew()
function Log([string]$m) { Write-Host ("[{0,6:n1}s] {1}" -f $sw.Elapsed.TotalSeconds, $m) }
function Step([string]$Key, [scriptblock]$Body) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    try { $v = & $Body; $res.steps[$Key] = [ordered]@{ ok = $true; sec = [math]::Round($t.Elapsed.TotalSeconds, 1) }; Log "$Key ok ($([math]::Round($t.Elapsed.TotalSeconds,1)) s)"; $v }
    catch { $res.steps[$Key] = [ordered]@{ ok = $false; sec = [math]::Round($t.Elapsed.TotalSeconds, 1); error = "$_" }; Log "$Key FAILED: $_"; throw }
}

$Exe = (Resolve-Path $Exe).Path
try { $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) }
catch [IO.IOException] { throw "The lab lock is held: $(Get-Content $lock -Raw)" }
$fs.Write([Text.Encoding]::UTF8.GetBytes("lab069 pid=$PID $(Get-Date -Format o)")); $fs.Close()
$wasRunning = (Get-Service GpuVM -ErrorAction SilentlyContinue).Status -eq 'Running'
try {
    if ($wasRunning) { Stop-Service GpuVM -Force; Log 'installed GpuVM service stopped for the run' }
    & schtasks.exe /create /tn $task /tr "`"$Exe`" broker" /sc once /st 00:00 /ru SYSTEM /rl HIGHEST /f | Out-Null
    & schtasks.exe /run /tn $task | Out-Null
    $t = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path '\\.\pipe\gpuvm-agent')) { if ($t.Elapsed.TotalSeconds -gt 20) { throw 'the broker did not open its pipe' }; Start-Sleep -Milliseconds 300 }

    $module = Import-Module (Join-Path $here '..\..\src\GpuVM\GpuVM.psd1') -Force -PassThru -DisableNameChecking
    $res.backendOnThisPc = & $module { Resolve-GpuVMBackendName -Requested '' }
    $res.hostCheck = @(Test-GpuVMHost | ForEach-Object { "$($_.Name)=$($_.Status)" })
    Step 'new' { New-GpuVM -Name $name -Template $Template -Override @{ backend = 'hcs' } -Confirm:$false | Out-Null }
    $res.listed = Step 'list' { @(Get-GpuVM | Where-Object Name -eq $name | ForEach-Object { "$($_.Name) $($_.State) $($_.Backend)" }) }
    Step 'start' { Invoke-GpuVMPower -Name $name -Action Start | Out-Null }
    $cred = & $module { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $name
    Step 'ready' { & $module { param($n, $c) Wait-GuestReady -Name $n -Credential $c -TimeoutSec 600 } $name $cred }
    $res.guestCommand = Step 'guest-command' { & $module { param($n, $c) Invoke-Guest -Name $n -Credential $c -ArgumentList 'ok' -ScriptBlock { param($x) "$x $env:COMPUTERNAME $([Environment]::OSVersion.Version)" } } $name $cred }
    $res.gpuInGuest = Step 'gpu' { & $module { param($n, $c) Invoke-Guest -Name $n -Credential $c -ScriptBlock { (Get-CimInstance Win32_VideoController | Where-Object Name -like '*NVIDIA*').Name } } $name $cred }
    $res.address = Step 'address' { & $module { param($n) Get-GpuVMAddress -Name $n -TimeoutSec 120 } $name }
    $router = (Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Sort-Object RouteMetric | Select-Object -First 1).NextHop
    $res.isolation = Step 'isolation' {
        & $module { param($n, $c, $r) Invoke-Guest -Name $n -Credential $c -ArgumentList $r -ScriptBlock {
            param($router)
            $deadline = (Get-Date).AddSeconds(90)
            do { $web = & curl.exe -s -o NUL -m 10 -w '%{http_code}' https://www.microsoft.com/; if ($web -ne '200') { Start-Sleep 3 } } while ($web -ne '200' -and (Get-Date) -lt $deadline)
            $lan = & curl.exe -s -o NUL -m 5 -w '%{http_code}' "http://${router}/"; $lanExit = $LASTEXITCODE
            [ordered]@{ internet = $web; lanRouter = "$lan exit=$lanExit" }
        } } $name $cred $router
    }
    if ($res.isolation.internet -ne '200' -or $res.isolation.lanRouter -notmatch 'exit=(7|28)') { throw "isolation: $($res.isolation | ConvertTo-Json -Compress)" }
    if ($Connect) {
        Step 'connect' { Connect-GpuVM -Name $name | Out-Null }
        Start-Sleep 15
        Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    Step 'stop' { Invoke-GpuVMPower -Name $name -Action Shutdown | Out-Null }
    $res.stateAfterStop = (Get-GpuVM | Where-Object Name -eq $name).State
    Step 'remove' { Remove-GpuVM -Name $name -DeleteDisk -Confirm:$false | Out-Null }
    $res.gone = -not (Test-Path "C:\GpuVM\$name")
} catch { $res.error = "$_"; Log "FAILED: $_"; $res.errorAt = $_.InvocationInfo.PositionMessage }
finally {
    try { if (Test-Path "C:\GpuVM\$name\hcs-machine.json") { & $Exe hcs off C:\GpuVM $name | Out-Null; & $Exe hcs delete C:\GpuVM $name | Out-Null } } catch { }
    & $Exe hcs network-delete | Out-Null
    & schtasks.exe /end /tn $task 2>$null | Out-Null
    Get-CimInstance Win32_Process -Filter "Name='gpuvm-host.exe'" | Where-Object ExecutablePath -eq $Exe | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    & schtasks.exe /delete /tn $task /f 2>$null | Out-Null
    if ($wasRunning) { Start-Service GpuVM; Log 'installed GpuVM service started again' }
    $res.totalSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $res | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $outDir "$runId.json")
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
    Log "done -> out/$runId.json; left behind: machine=$(Test-Path "C:\GpuVM\$name") lock=$(Test-Path $lock)"
}
