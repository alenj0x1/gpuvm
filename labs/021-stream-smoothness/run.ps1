# Lab 021: how evenly the picture moves with each FPS, V-Sync and frame pacing setting (for the "Movies" and "Work"
# uses), measured on a bar crossing the screen at constant speed in the VM (tools/latency/motion-target.ps1).
#   local    the bar runs on this PC, without streaming: the best this monitor can show
#   <name>   the bar runs in the VM; Moonlight opens with that variant's settings (borderless)
# Variants run in interleaved rounds. Only reads the screen: no input is sent to Moonlight or this PC.
# Run elevated (PowerShell Direct, the VM's display mode), in the signed-in user's session:
#   pwsh -File labs/021-stream-smoothness/run.ps1 -Name win10 -Rounds 2
param(
    [string]$Name = 'win10',
    [string[]]$Only,
    # Other variants instead of the built-in ones: @{ Name = '...'; Client = @{ fps = 180; vsync = $true } } each.
    [hashtable[]]$Custom,
    [int]$Rounds = 2,
    [double]$Seconds = 20,
    [switch]$SkipLocal,
    [string]$Out = (Join-Path $PSScriptRoot "out\run-$(Get-Date -Format 'yyyyMMdd-HHmmss').json")
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
$tools = Join-Path $PSScriptRoot '..\..\tools\latency'
. (Join-Path $tools 'common.ps1')
. (Join-Path $tools 'input-meter.ps1')
. (Join-Path $tools 'motion-meter.ps1')

# Moonlight only paces frames with V-Sync on, so pacing is never combined with V-Sync off.
$variants = @(
    foreach ($fps in 60, 120, 165) {
        [pscustomobject]@{ Name = "$fps-vsync-pacing"; Client = @{ fps = $fps; vsync = $true; framePacing = $true } }
        [pscustomobject]@{ Name = "$fps-vsync"; Client = @{ fps = $fps; vsync = $true; framePacing = $false } }
        [pscustomobject]@{ Name = "$fps-novsync"; Client = @{ fps = $fps; vsync = $false; framePacing = $false } }
    }
) | Where-Object { -not $Only -or $_.Name -in $Only }
if ($Custom) { $variants = $Custom | ForEach-Object { [pscustomobject]$_ } }

function Get-VideoBounds([IntPtr]$Window, [int]$Width, [int]$Height) {
    $c = [GpuVMInputMeter]::ClientBounds($Window)
    $scale = [math]::Min($c[2] / $Width, $c[3] / $Height)
    $w = [int]($Width * $scale); $h = [int]($Height * $scale)
    [System.Drawing.Rectangle]::new($c[0] + [int](($c[2] - $w) / 2), $c[1] + [int](($c[3] - $h) / 2), $w, $h)
}

$results = [System.Collections.Generic.List[object]]::new()
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$hostHz = (Get-CimInstance Win32_VideoController | Where-Object CurrentRefreshRate | Select-Object -First 1).CurrentRefreshRate

if (-not $SkipLocal) {
    $target = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $tools 'motion-target.ps1')`"", '-Minutes', '2'
    Start-Sleep -Seconds 5
    $row = Measure-Motion -Bounds $screen -Fps $hostHz -Seconds $Seconds
    $row | Add-Member variant 'local' -PassThru | Add-Member round 1 -PassThru | Add-Member fps $hostHz | Out-Null
    $results.Add($row)
    "local: $($row | ConvertTo-Json -Compress)" | Write-Host
    Stop-Process -Id $target.Id -Force -ErrorAction SilentlyContinue
}

$vm = Get-LatencyVM -Name $Name
$state = & $vm.Module { param($n) Get-GpuVMState -Name $n } $Name
$saved = $state['config']['streaming']['client']
& (Join-Path $tools 'start-target.ps1') -Name $Name -Minutes 120 -Script motion-target.ps1 | Write-Host
$guestFps = $null
try {
    for ($round = 1; $round -le $Rounds; $round++) {
        foreach ($variant in $variants) {
            $client = [ordered]@{}
            foreach ($k in $saved.Keys) { $client[$k] = $saved[$k] }
            $client['displayMode'] = 'borderless'
            foreach ($k in $variant.Client.Keys) { $client[$k] = $variant.Client[$k] }
            $fps = [int]$client['fps']
            $width, $height = [int[]]("$($client['resolution'])" -split 'x')
            if ($guestFps -ne $fps) {
                $set = & $vm.Module { param($n, $c, $r, $f) Set-GuestDisplayResolution -Name $n -Credential $c -Resolution $r -Fps $f } $Name $vm.Guest $client['resolution'] $fps
                $guestFps = $fps
                "guest display $($client['resolution'])@$fps : $($set | ConvertTo-Json -Compress)" | Write-Host
                Start-Sleep -Seconds 2
            }
            $arguments = & $vm.Module { param($a, $c) Get-MoonlightStreamArguments -Address $a -Client $c } $vm.Address $client
            Get-Process Moonlight -ErrorAction SilentlyContinue | Stop-Process -Force
            $started = Get-Date
            $process = Start-Process (Join-Path $env:ProgramFiles 'Moonlight Game Streaming\Moonlight.exe') -ArgumentList $arguments -PassThru
            $firstFrameSec = Wait-LatencyStreamVisible -Since $started
            $process.Refresh()
            if (-not [GpuVMInputMeter]::BringToFront($process.MainWindowHandle)) { 'Moonlight is not in front: the picture may be covered' | Write-Host }
            Start-Sleep -Milliseconds 500
            $bounds = Get-VideoBounds $process.MainWindowHandle $width $height
            # Moonlight logs its first frame before the picture shows (black for a few seconds, longer after a reconnect):
            # wait until the bar moves on screen, up to 60 s, then 2 s more so the stream settles.
            $wait = [Diagnostics.Stopwatch]::StartNew()
            $pictureSec = -1
            while ($wait.Elapsed.TotalSeconds -lt 60) {
                $probe = Measure-Motion -Bounds $bounds -Fps $fps -Seconds 0.5
                if (-not $probe.PSObject.Properties['error']) { $pictureSec = [math]::Round($firstFrameSec + $wait.Elapsed.TotalSeconds, 1); break }
            }
            "$($variant.Name) r$round picture after $pictureSec s" | Write-Host
            Start-Sleep -Seconds 2
            $row = Measure-Motion -Bounds $bounds -Fps $fps -Seconds $Seconds
            $row | Add-Member variant $variant.Name -PassThru | Add-Member round $round -PassThru | Add-Member fps $fps -PassThru |
                Add-Member firstFrameSec $firstFrameSec -PassThru | Add-Member startedAt $started.ToString("o") -PassThru | Add-Member pictureSec $pictureSec -PassThru | Add-Member arguments ($arguments -join ' ') | Out-Null
            $results.Add($row)
            if ($row.PSObject.Properties['error']) {
                Save-ScreenRegion -Path (Join-Path (Split-Path $Out) "$($variant.Name)-r$round-error.png")
                $guest = Invoke-Command -VMName $Name -Credential $vm.Guest -ScriptBlock {
                    $s = Get-ChildItem C:\Users\*\AppData\Local\Temp\gpuvm-motion-target.txt -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content
                    $p = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object CommandLine -like '*latency-target*').Count
                    # What the VM's own screen shows (in the user's session), to tell a black stream from a black VM.
                    $code = "Add-Type -AssemblyName System.Windows.Forms, System.Drawing; `$b = [System.Windows.Forms.SystemInformation]::VirtualScreen; `$bmp = New-Object System.Drawing.Bitmap `$b.Width, `$b.Height; [System.Drawing.Graphics]::FromImage(`$bmp).CopyFromScreen(`$b.Left, `$b.Top, 0, 0, `$bmp.Size); `$bmp.Save('C:\GpuVM\screen.png')"
                    Set-Content C:\GpuVM\shot.ps1 $code
                    $user = (Get-CimInstance Win32_ComputerSystem).UserName
                    $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\GpuVM\shot.ps1'
                    Register-ScheduledTask -TaskName GpuVM-Shot -Action $a -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
                    Remove-Item C:\GpuVM\screen.png -ErrorAction SilentlyContinue
                    Start-ScheduledTask GpuVM-Shot; Start-Sleep 6
                    Unregister-ScheduledTask GpuVM-Shot -Confirm:$false
                    $png = if (Test-Path C:\GpuVM\screen.png) { [Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\GpuVM\screen.png')) }
                    [pscustomobject]@{ Text = "target processes $p, status: $s"; Png = $png }
                }
                if ($guest.Png) { [IO.File]::WriteAllBytes((Join-Path (Split-Path $Out) "$($variant.Name)-r$round-guest.png"), [Convert]::FromBase64String($guest.Png)) }
                $guest = $guest.Text
                "$($variant.Name) r$round : $($row.error) ($guest)" | Write-Host
            }
            else { "$($variant.Name) r$round : updates/s $($row.updatesPerSec) sd $($row.intervalSdMs) ms p99 $($row.intervalP99Ms) ms stutter $($row.stutterPct) % speedCV $($row.speedCvPct) %" | Write-Host }
            Stop-LatencyStream ([pscustomobject]@{ Process = $process }) -VM $vm
        }
    }
}
finally {
    [pscustomobject]@{
        measuredAt = (Get-Date).ToString('o')
        vm = $Name
        hostScreen = "$($screen.Width)x$($screen.Height)@$hostHz"
        saved = $saved
        results = @($results)
    } | ConvertTo-Json -Depth 6 | Set-Content -Path $Out -Encoding utf8
    "saved $Out" | Write-Host
    if ($guestFps -and $guestFps -ne [int]$saved['fps']) {
        $null = & $vm.Module { param($n, $c, $r, $f) Set-GuestDisplayResolution -Name $n -Credential $c -Resolution $r -Fps $f } $Name $vm.Guest $saved['resolution'] ([int]$saved['fps'])
    }
    & (Join-Path $tools 'stop-target.ps1') -Name $Name | Write-Host
}

