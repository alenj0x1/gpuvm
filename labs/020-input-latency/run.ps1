# Lab 020: end-to-end input latency (key, click, mouse move, gamepad button) from the host to Moonlight's picture.
#   local    the input target runs on this PC, without streaming: what the meter, the target and DWM cost by themselves
#   <name>   the target runs in the VM; Moonlight is opened with that variant's settings and measured the same way
# Variants run in interleaved rounds (A B C ... A B C ...) so drift over time doesn't favor one of them.
# Takes over the screen, mouse and keyboard while it runs. With -Pad, a beep asks for ~40 slow presses of A on a pad
# connected to this PC, for the local reference and for each variant.
# Run elevated (PowerShell Direct, the VM's display mode), in the signed-in user's session:
#   pwsh -File labs/020-input-latency/run.ps1 -Name win10 -Rounds 2
param(
    [string]$Name = 'win10',
    [string[]]$Only,
    # Other variants instead of the built-in ones: @{ Name = '...'; Client = @{ fps = 180; vsync = $true } } each.
    [hashtable[]]$Custom,
    [int]$Rounds = 2,
    [int]$Samples = 40,
    [switch]$SkipLocal,
    [switch]$Pad,
    [int]$PadSamples = 30,
    [string]$Out = (Join-Path $PSScriptRoot "out\run-$(Get-Date -Format 'yyyyMMdd-HHmmss').json")
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
$tools = Join-Path $PSScriptRoot '..\..\tools\latency'
. (Join-Path $tools 'common.ps1')
. (Join-Path $tools 'input-meter.ps1')

# Each variant changes the client settings GpuVM saved for the VM (baseline = as GpuVM opens it today).
$variants = @(
    [pscustomobject]@{ Name = 'baseline'; Client = @{} }
    [pscustomobject]@{ Name = 'borderless-novsync'; Client = @{ displayMode = 'borderless'; vsync = $false; framePacing = $false } }
    [pscustomobject]@{ Name = 'fullscreen-novsync'; Client = @{ displayMode = 'fullscreen'; vsync = $false; framePacing = $false } }
    [pscustomobject]@{ Name = 'borderless-novsync-60'; Client = @{ displayMode = 'borderless'; vsync = $false; framePacing = $false; fps = 60 } }
    [pscustomobject]@{ Name = 'borderless-novsync-180'; Client = @{ displayMode = 'borderless'; vsync = $false; framePacing = $false; fps = 180 } }
    [pscustomobject]@{ Name = 'borderless-novsync-h264'; Client = @{ displayMode = 'borderless'; vsync = $false; framePacing = $false; codec = 'H.264' } }
    [pscustomobject]@{ Name = 'borderless-novsync-av1'; Client = @{ displayMode = 'borderless'; vsync = $false; framePacing = $false; codec = 'AV1' } }
) | Where-Object { -not $Only -or $_.Name -in $Only -or $_.Name -eq 'baseline' }
if ($Custom) { $variants = $Custom | ForEach-Object { [pscustomobject]$_ } }

function Get-VideoBounds([IntPtr]$Window, [int]$Width, [int]$Height) {
    # Moonlight letterboxes the stream inside its window at the stream's aspect ratio.
    $c = [GpuVMInputMeter]::ClientBounds($Window)
    $scale = [math]::Min($c[2] / $Width, $c[3] / $Height)
    $w = [int]($Width * $scale); $h = [int]($Height * $scale)
    [System.Drawing.Rectangle]::new($c[0] + [int](($c[2] - $w) / 2), $c[1] + [int](($c[3] - $h) / 2), $w, $h)
}

# The pad is measured in the first round only (a person presses it); a box in the corner counts the presses.
function Invoke-Pass([System.Drawing.Rectangle]$Bounds, [bool]$WithPad, [IntPtr]$Window = [IntPtr]::Zero) {
    # A few discarded samples first: the first click captures the mouse in Moonlight.
    # Clicks first: Moonlight takes the keyboard only after a click captures the mouse.
    $null = Measure-InputLatency -Bounds $Bounds -Window $Window -Kinds click, key, move -Samples 3
    $fast = Measure-InputLatency -Bounds $Bounds -Window $Window -Kinds key, click, move -Samples $Samples
    $slow = if ($WithPad) { Measure-InputLatency -Bounds $Bounds -Window $Window -Kinds pad -Samples $PadSamples -PadWaitSec 30 }
    @($fast) + @($slow | Where-Object { $_ })
}

$results = [System.Collections.Generic.List[object]]::new()
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

if (-not $SkipLocal) {
    $target = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $tools 'input-target.ps1')`"", '-Minutes', '5'
    Start-Sleep -Seconds 5
    [GpuVMInputMeter]::SetCursorPos($screen.Left + $screen.Width / 10, $screen.Top + $screen.Height / 6) | Out-Null
    foreach ($row in Invoke-Pass $screen $Pad.IsPresent) { $row | Add-Member variant 'local' -PassThru | Add-Member round 1 -PassThru | ForEach-Object { $results.Add($_) }; "local $($row.kind): median $($row.medianMs) p95 $($row.p95Ms) misses $($row.misses)" | Write-Host }
    Stop-Process -Id $target.Id -Force -ErrorAction SilentlyContinue
}

$vm = Get-LatencyVM -Name $Name
$state = & $vm.Module { param($n) Get-GpuVMState -Name $n } $Name
$saved = $state['config']['streaming']['client']
& (Join-Path $tools 'start-target.ps1') -Name $Name -Minutes 120 -Script input-target.ps1 | Write-Host
# Sunshine creates the VM's virtual pad through ViGEmBus; without it nothing reaches the target.
$guestPad = $Pad -and (Invoke-Command -VMName $Name -Credential $vm.Guest -ScriptBlock { [bool](Get-Service ViGEmBus -ErrorAction SilentlyContinue) })
if ($Pad -and -not $guestPad) { 'ViGEmBus is not installed in the VM: the pad is measured locally only.' | Write-Host }
$guestFps = $null
try {
    for ($round = 1; $round -le $Rounds; $round++) {
        foreach ($variant in $variants) {
            $client = [ordered]@{}
            foreach ($k in $saved.Keys) { $client[$k] = $saved[$k] }
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
            $session = [pscustomobject]@{ Process = $process }
            $firstFrameSec = Wait-LatencyStreamVisible -Since $started
            Start-Sleep -Seconds 5
            $process.Refresh()
            $window = $process.MainWindowHandle
            if (-not [GpuVMInputMeter]::BringToFront($window)) { "Moonlight is not in front: inputs may go elsewhere" | Write-Host }
            Start-Sleep -Milliseconds 300
            $bounds = Get-VideoBounds $window $width $height
            # The host pointer goes over the stream so the first click lands in Moonlight and captures the mouse.
            [void][GpuVMInputMeter]::SetCursorPos($bounds.Left + $bounds.Width / 2, $bounds.Top + $bounds.Height / 6)
            # The picture can stay black for a while after Moonlight reports its first frame (lab 021): click until the
            # click square answers, up to 60 s, before measuring.
            $wait = [Diagnostics.Stopwatch]::StartNew()
            $click = Get-InputSquarePoint -Bounds $bounds -Index 1
            while ($wait.Elapsed.TotalSeconds -lt 60 -and [GpuVMInputMeter]::Measure(1, $click.X, $click.Y, 500, $window) -lt 0) { Start-Sleep -Milliseconds 300 }
            "$($variant.Name) r$round picture after $([math]::Round($firstFrameSec + 5 + $wait.Elapsed.TotalSeconds, 1)) s" | Write-Host
            Start-Sleep -Milliseconds 300
            foreach ($row in Invoke-Pass $bounds ($guestPad -and $round -eq 1) $window) {
                $row | Add-Member variant $variant.Name -PassThru | Add-Member round $round -PassThru |
                    Add-Member fps $fps -PassThru | Add-Member firstFrameSec $firstFrameSec -PassThru | Add-Member startedAt $started.ToString("o") -PassThru |
                    Add-Member arguments ($arguments -join ' ') -PassThru | ForEach-Object { $results.Add($_) }
                "$($variant.Name) r$round $($row.kind): median $($row.medianMs) p95 $($row.p95Ms) misses $($row.misses)" | Write-Host
            }
            Stop-LatencyStream $session -VM $vm
        }
    }
}
finally {
    [pscustomobject]@{
        measuredAt = (Get-Date).ToString('o')
        vm = $Name
        hostScreen = "$($screen.Width)x$($screen.Height)"
        saved = $saved
        results = @($results)
    } | ConvertTo-Json -Depth 6 | Set-Content -Path $Out -Encoding utf8
    "saved $Out" | Write-Host
    if ($guestFps -and $guestFps -ne [int]$saved['fps']) {
        $null = & $vm.Module { param($n, $c, $r, $f) Set-GuestDisplayResolution -Name $n -Credential $c -Resolution $r -Fps $f } $Name $vm.Guest $saved['resolution'] ([int]$saved['fps'])
    }
    & (Join-Path $tools 'stop-target.ps1') -Name $Name | Write-Host
}
