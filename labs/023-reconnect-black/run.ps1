# Lab 023: how long the picture stays black when Moonlight connects to a VM that is already on, without a display
# change in between. Opens Moonlight -Count times in a row with the VM's saved settings and, for each session, times
#   firstFrameSec    Moonlight's log says "Video stream is" (its first frame arrived)
#   pictureSec       the bar of tools/latency/motion-target.ps1 moves on this screen (the picture really shows)
#   sunshineSec      from Sunshine's "Executing" to its "Capture format" (its first real frame; none = no capture restart)
#   focusLost        times Moonlight had to be brought back to the front (a covered window hides the picture)
# Sunshine's log goes to debug level during the run (restored afterwards) so it says why the capture restarts.
# -Settings writes other sunshine.conf keys for the run (a candidate fix), also restored afterwards.
# -Capture switches Sunshine's capture (ddx or wgc, through GpuVM) for the run and back afterwards.
# Only reads the screen. Run elevated, in the signed-in user's session:
#   pwsh -File labs/023-reconnect-black/run.ps1 -Name win10 -Count 10
param(
    [string]$Name = 'win10',
    [int]$Count = 10,
    [int]$PauseSec = 5,
    [hashtable]$Settings = @{},
    [ValidateSet('', 'ddx', 'wgc')][string]$Capture = '',
    # What the VM shows during the run: the bar full screen, the bar in a normal window, or nothing (idle desktop).
    [ValidateSet('fullscreen', 'windowed', 'none')][string]$Target = 'fullscreen',
    [string]$Label = 'baseline',
    [string]$OutDir = (Join-Path $PSScriptRoot "out\$(Get-Date -Format 'yyyyMMdd-HHmmss')-$Label")
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$tools = Join-Path $PSScriptRoot '..\..\tools\latency'
. (Join-Path $tools 'common.ps1')
. (Join-Path $tools 'input-meter.ps1')
. (Join-Path $tools 'motion-meter.ps1')
# A VM that is off is started and given time for Windows and Sunshine (the first session after boot is not a reconnect).
if ((Get-VM -Name $Name).State -ne 'Running') {
    'starting the VM' | Write-Host
    Start-VM -Name $Name
    $mod = Get-Module GpuVM
    while (-not (& $mod { param($n) Test-GuestHeartbeat -Name $n } $Name)) { Start-Sleep -Seconds 2 }
    Start-Sleep -Seconds 90
}
$vm = Get-LatencyVM -Name $Name
& $vm.Module { param($a, $c) Wait-SunshineReady -Address $a -Credential $c -TimeoutSec 300 -Message 'Esperando a Sunshine' } $vm.Address $vm.Sunshine
$state = & $vm.Module { param($n) Get-GpuVMState -Name $n } $Name
$client = $state['config']['streaming']['client']
$width, $height = [int[]]("$($client['resolution'])" -split 'x')
$fps = & $vm.Module { param($f) Resolve-GpuVMStreamFps $f } $client['fps']

# Current values of every key the run changes, to put them back.
$config = & $vm.Module { param($a, $c) Invoke-SunshineApi -Address $a -Credential $c -Path '/api/config' } $vm.Address $vm.Sunshine
$change = [ordered]@{ min_log_level = 'debug' }
foreach ($k in $Settings.Keys) { $change[$k] = $Settings[$k] }
$restore = [ordered]@{}
foreach ($k in $change.Keys) { $restore[$k] = if ($config.PSObject.Properties[$k]) { $config.$k } else { $null } }
$config | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutDir 'sunshine-config.json') -Encoding utf8
"sunshine: capture=$($config.PSObject.Properties['capture']?.Value) dd=$($config.PSObject.Properties['dd_configuration_option']?.Value) changing $($change.Keys -join ',')" | Write-Host

function Get-VideoBounds([IntPtr]$Window) {
    $c = [GpuVMInputMeter]::ClientBounds($Window)
    $scale = [math]::Min($c[2] / $width, $c[3] / $height)
    $w = [int]($width * $scale); $h = [int]($height * $scale)
    [System.Drawing.Rectangle]::new($c[0] + [int](($c[2] - $w) / 2), $c[1] + [int](($c[3] - $h) / 2), $w, $h)
}

$results = [System.Collections.Generic.List[object]]::new()
try {
    & $vm.Module { param($a, $c, $s) Update-SunshineConfig -Address $a -Credential $c -Settings $s } $vm.Address $vm.Sunshine $change | Out-Null
    $savedCapture = & $vm.Module { param($s) Get-GpuVMCaptureMode -State $s } $state
    if ($Capture -and $Capture -ne $savedCapture) {
        "capture $savedCapture -> $Capture : $(& $vm.Module { param($n, $c, $m) Set-GuestCaptureMode -Name $n -Credential $c -Mode $m } $Name $vm.Guest $Capture)" | Write-Host
        & $vm.Module { param($a, $c) Wait-SunshineReady -Address $a -Credential $c -TimeoutSec 180 -Message 'Esperando a Sunshine' } $vm.Address $vm.Sunshine
        Start-Sleep -Seconds 10
    }
    $set = & $vm.Module { param($n, $c, $r, $f) Set-GuestDisplayResolution -Name $n -Credential $c -Resolution $r -Fps $f } $Name $vm.Guest $client['resolution'] $fps
    "guest display: $($set | ConvertTo-Json -Compress)" | Write-Host
    if ($Target -ne 'none') { & (Join-Path $tools 'start-target.ps1') -Name $Name -Minutes 60 -Script motion-target.ps1 -Windowed:($Target -eq 'windowed') | Write-Host }
    $arguments = & $vm.Module { param($a, $c) Get-MoonlightStreamArguments -Address $a -Client $c } $vm.Address $client
    for ($i = 1; $i -le $Count; $i++) {
        Get-Process Moonlight -ErrorAction SilentlyContinue | Stop-Process -Force
        $started = Get-Date
        $process = Start-Process (Join-Path $env:ProgramFiles 'Moonlight Game Streaming\Moonlight.exe') -ArgumentList $arguments -PassThru
        $first = Wait-LatencyStreamVisible -Since $started -TimeoutSec 60
        $process.Refresh()
        [void][GpuVMInputMeter]::BringToFront($process.MainWindowHandle)
        $bounds = Get-VideoBounds $process.MainWindowHandle
        $picture = -1
        $focusLost = 0
        # Without the bar there is nothing to see on the host: only Sunshine's log times the session (30 s each).
        if ($Target -eq 'none') { Start-Sleep -Seconds 30 }
        while ($Target -ne 'none' -and ((Get-Date) - $started).TotalSeconds -lt 90) {
            # The picture is only readable while Moonlight is in front; bring it back when something covers it.
            if (-not [GpuVMInputMeter]::BringToFront($process.MainWindowHandle)) { $focusLost++ }
            $probe = Measure-Motion -Bounds $bounds -Fps $fps -Seconds 0.5
            if (-not $probe.PSObject.Properties['error']) { $picture = [math]::Round(((Get-Date) - $started).TotalSeconds - 0.5, 1); break }
        }
        $results.Add([pscustomobject]@{ session = $i; startedAt = $started.ToString('o'); firstFrameSec = $first; pictureSec = $picture; focusLost = $focusLost })
        "session $i : first frame $first s, picture $picture s, focus lost $focusLost" | Write-Host
        Stop-LatencyStream ([pscustomobject]@{ Process = $process }) -VM $vm
        Start-Sleep -Seconds $PauseSec
    }
}
finally {
    # Each clean-up step runs on its own: one failing (Sunshine slow to come back) must not skip the rest.
    $step = { param($what, $block) try { & $block } catch { Write-Warning "$what failed: $($_.Exception.Message)" } }
    $log = ''
    & $step 'saving Sunshine log' {
        $script:log = & $vm.Module { param($a, $c) Invoke-SunshineApi -Address $a -Credential $c -Path '/api/logs' } $vm.Address $vm.Sunshine
        Set-Content -LiteralPath (Join-Path $OutDir 'sunshine.log') -Value $script:log -Encoding utf8
    }
    $log = $script:log
    # Sunshine's own view of each session (DDX only): seconds from "Executing [app]" to "Capture format" (its first
    # real frame); 0 = no capture restart. WGC never logs "Capture format", so it stays empty there.
    $events = foreach ($line in ("$log" -split "`n")) {
        if ($line -match '^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\]: Info: (Executing \[|Capture format)') {
            [pscustomobject]@{ At = [datetime]$Matches[1]; Kind = if ($Matches[2] -like 'Exec*') { 'exec' } else { 'capture' } }
        }
    }
    foreach ($r in $results) {
        $start = [datetime]$r.startedAt
        $exec = $events | Where-Object { $_.Kind -eq 'exec' -and $_.At -ge $start } | Select-Object -First 1
        $next = if ($exec) { $events | Where-Object { $_.Kind -eq 'exec' -and $_.At -gt $exec.At } | Select-Object -First 1 }
        $cap = if ($exec) { $events | Where-Object { $_.Kind -eq 'capture' -and $_.At -gt $exec.At -and (-not $next -or $_.At -lt $next.At) } | Select-Object -First 1 }
        $value = if ($Capture -eq 'wgc') { $null } elseif ($cap) { [math]::Round(($cap.At - $exec.At).TotalSeconds, 1) } elseif ($exec) { 0 } else { $null }
        $r | Add-Member sunshineSec $value -Force
    }
    $pictures = @($results | Where-Object pictureSec -ge 0 | ForEach-Object pictureSec | Sort-Object)
    $sunshine = @($results | Where-Object { $null -ne $_.sunshineSec } | ForEach-Object sunshineSec | Sort-Object)
    [pscustomobject]@{
        label = $Label; vm = $Name; fps = $fps; capture = $Capture; target = $Target; settings = $change; sessions = @($results)
        pictureMedianSec = if ($pictures) { $pictures[[int][math]::Floor(($pictures.Count - 1) / 2)] } else { $null }
        pictureMaxSec = if ($pictures) { $pictures[-1] } else { $null }
        neverShown = @($results | Where-Object pictureSec -lt 0).Count
        sunshineMedianSec = if ($sunshine) { $sunshine[[int][math]::Floor(($sunshine.Count - 1) / 2)] } else { $null }
    } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutDir 'result.json') -Encoding utf8
    "saved $OutDir" | Write-Host
    & $step 'closing the target' { & (Join-Path $tools 'stop-target.ps1') -Name $Name | Write-Host }
    if ($Capture -and $Capture -ne $savedCapture) {
        & $step 'capture back' {
            & $vm.Module { param($n, $c, $m) Set-GuestCaptureMode -Name $n -Credential $c -Mode $m } $Name $vm.Guest $savedCapture | Out-Null
            & $vm.Module { param($a, $c) Wait-SunshineReady -Address $a -Credential $c -TimeoutSec 300 -Message 'Sunshine vuelve a la captura anterior' } $vm.Address $vm.Sunshine
            "capture back to $savedCapture" | Write-Host
        }
    }
    & $step 'restoring sunshine.conf' { & (Join-Path $PSScriptRoot 'restore.ps1') -Name $Name -Restore $restore }
}

