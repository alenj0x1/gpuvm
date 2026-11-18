# References measured inside a VM, without streaming: the target and the meter both run in the VM's desktop session,
# so the VM's own cost is told apart from what the stream adds.
#   -Kind input   input latency (input-target + input-meter): input to the VM's composed screen
#   -Kind motion  smoothness (motion-target + motion-meter): how often the VM's own screen shows the bar move
# Run as administrator on the host; the meter runs in the VM through a one-shot task of the signed-in user.
#   tools/latency/guest-local.ps1 -Name win-gpu [-Kind motion] [-Windowed]
# Takes over the VM's screen for about a minute; no stream may be open (the target covers the VM's desktop).
param(
    [Parameter(Mandatory)][string]$Name,
    [ValidateSet('input', 'motion')][string]$Kind = 'input',
    [int]$Samples = 40,
    [double]$Seconds = 15,
    # motion: the target as a normal window over 70 % of the screen instead of full screen.
    [switch]$Windowed,
    [string]$Out = (Join-Path $PSScriptRoot "..\..\labs\$(if ($Kind -eq 'input') { '020-input-latency' } else { '021-stream-smoothness' })\out\guest-$Kind-$(Get-Date -Format 'yyyyMMdd-HHmmss').json")
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$vm = Get-LatencyVM -Name $Name
$session = New-PSSession -VMName $Name -Credential $vm.Guest
try {
    Invoke-Command -Session $session { New-Item -ItemType Directory -Force C:\GpuVM\latency | Out-Null; Remove-Item C:\GpuVM\latency\result.json -ErrorAction SilentlyContinue }
    $files = if ($Kind -eq 'input') { 'input-target.ps1', 'input-meter.ps1' } else { 'motion-target.ps1', 'motion-meter.ps1' }
    foreach ($f in $files) { Copy-Item (Join-Path $PSScriptRoot $f) -Destination C:\GpuVM\latency\ -ToSession $session -Force }
    $measure = if ($Kind -eq 'input') {
        @"
    . C:\GpuVM\latency\input-meter.ps1
    [void][GpuVMInputMeter]::SetCursorPos(`$screen.Left + `$screen.Width / 10, `$screen.Top + `$screen.Height / 6)
    `$null = Measure-InputLatency -Bounds `$screen -Kinds click, key, move -Samples 3
    `$rows = @(Measure-InputLatency -Bounds `$screen -Kinds key, click, move -Samples $Samples)
"@
    } else {
        # The windowed target sits at 15 %..85 % of the screen: the meter reads inside it.
        $bounds = if ($Windowed) { '[System.Drawing.Rectangle]::new([int]($screen.Width * 0.2), [int]($screen.Height * 0.2), [int]($screen.Width * 0.6), [int]($screen.Height * 0.6))' } else { '$screen' }
        @"
    . C:\GpuVM\latency\motion-meter.ps1
    `$hz = (Get-CimInstance Win32_VideoController | Where-Object CurrentRefreshRate | Select-Object -First 1).CurrentRefreshRate
    `$rows = @(Measure-Motion -Bounds ($bounds) -Fps `$hz -Seconds $Seconds | Add-Member hz `$hz -PassThru)
"@
    }
    $target = if ($Kind -eq 'input') { 'input-target.ps1' } else { 'motion-target.ps1' }
    $extra = if ($Windowed) { ",'-Windowed'" } else { '' }
    $run = @"
`$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    `$target = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\GpuVM\latency\$target','-Minutes','3'$extra
    Start-Sleep -Seconds 5
    `$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$measure
    Stop-Process -Id `$target.Id -Force -ErrorAction SilentlyContinue
    @{ screen = "`$(`$screen.Width)x`$(`$screen.Height)"; results = `$rows } | ConvertTo-Json -Depth 5 | Set-Content C:\GpuVM\latency\result.json
} catch { @{ error = "`$_" } | ConvertTo-Json | Set-Content C:\GpuVM\latency\result.json }
"@
    $result = Invoke-Command -Session $session -ArgumentList $run -ScriptBlock {
        param($run)
        Set-Content C:\GpuVM\latency\run.ps1 $run
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\GpuVM\latency\run.ps1'
        Register-ScheduledTask -TaskName GpuVM-LatencyLocal -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
        try {
            Start-ScheduledTask GpuVM-LatencyLocal
            $deadline = (Get-Date).AddMinutes(4)
            while (-not (Test-Path C:\GpuVM\latency\result.json) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
        } finally { Unregister-ScheduledTask GpuVM-LatencyLocal -Confirm:$false -ErrorAction SilentlyContinue }
        if (Test-Path C:\GpuVM\latency\result.json) { Get-Content C:\GpuVM\latency\result.json -Raw } else { '{"error":"no result in 4 minutes"}' }
    }
    Set-Content -Path $Out -Value $result -Encoding utf8
    $data = $result | ConvertFrom-Json
    if ($data.PSObject.Properties['error']) { "error: $($data.error)" }
    elseif ($Kind -eq 'input') { foreach ($r in $data.results) { "guest-local $($r.kind): median $($r.medianMs) p95 $($r.p95Ms) misses $($r.misses)" } }
    else { foreach ($r in $data.results) { "guest-local motion$(if ($Windowed) { ' windowed' }) at $($r.hz) Hz: $($r | Select-Object * -ExcludeProperty hz | ConvertTo-Json -Compress)" } }
    "saved $Out"
}
finally {
    Invoke-Command -Session $session { Remove-Item C:\GpuVM\latency -Recurse -Force -ErrorAction SilentlyContinue } -ErrorAction SilentlyContinue
    Remove-PSSession $session
}
