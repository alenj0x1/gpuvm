# Lab 041's targets and named variants. Each variant: Name, optional Setup / Undo scriptblocks (param($vm)) and Client
# (stream settings over the VM's saved ones). Undo always runs, even when the measurement failed.

$script:Lab041Html = @'
<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;height:100%;background:#000;overflow:hidden;cursor:none}
#bar{position:absolute;top:0;left:0;width:24px;height:100%;background:#fff;will-change:transform}
</style></head><body><div id="bar"></div><script>
const bar = document.getElementById('bar');
function tick(t) { const w = innerWidth - 24; bar.style.transform = 'translateX(' + ((t / 2000) % 1) * w + 'px)'; requestAnimationFrame(tick); }
requestAnimationFrame(tick);
</script></body></html>
'@

# What runs on the VM's screen: 'gpu' (the bar in Edge, drawn on the GPU), 'input' (tools/latency/input-target.ps1)
# or 'none'.
function Start-Lab041Target($vm, [string]$Kind) {
    Invoke-Command -VMName $vm.Name -Credential $vm.Guest -ArgumentList $Kind, $script:Lab041Html -ScriptBlock {
        param($kind, $html)
        Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object CommandLine -like '*edge-bar*' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object CommandLine -like '*latency-target.ps1*' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        if ($kind -ne 'gpu') { if ($kind -eq 'none') { Remove-Item C:\GpuVM\bar.html, C:\GpuVM\edge-bar -Recurse -Force -ErrorAction SilentlyContinue }; return }
        New-Item -ItemType Directory -Force C:\GpuVM | Out-Null
        Set-Content C:\GpuVM\bar.html $html -Encoding utf8
        $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        $action = New-ScheduledTaskAction -Execute $edge -Argument '--kiosk file:///C:/GpuVM/bar.html --edge-kiosk-type=fullscreen --no-first-run --user-data-dir=C:\GpuVM\edge-bar'
        Register-ScheduledTask -TaskName GpuVM-BarTarget -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
        Start-ScheduledTask GpuVM-BarTarget; Start-Sleep -Seconds 4
        Unregister-ScheduledTask GpuVM-BarTarget -Confirm:$false
    }
    if ($Kind -eq 'input') { & (Join-Path $PSScriptRoot '..\..\tools\latency\start-target.ps1') -Name $vm.Name -Minutes 10 -Script input-target.ps1 | Out-Null }
}

# The installed GpuVM app, closed or open (its window shows Home: the hologram animates).
function Stop-Lab041App { Get-Process gpuvm -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 1 }
function Start-Lab041App {
    if (Get-Process gpuvm -ErrorAction SilentlyContinue) { return }
    & (Join-Path $PSScriptRoot '..\039-viewer-bridge\run-build.ps1') -Installed | Out-Null
    Start-Sleep -Seconds 6
}

# (Global: the variants' scriptblocks are closures, which don't see this script's own functions.)
# Sunshine settings in the VM: written in sunshine.conf directly, with the original file kept and put back exactly
# (keys absent before stay absent), and Sunshine restarted the way GpuVM does it in its capture mode (with WGC it runs
# from the user's logon task, and Sunshine's own /api/restart leaves it stopped).
function global:Restart-Lab041Sunshine($vm) {
    $state = & $vm.Module { param($n) Get-GpuVMState -Name $n } $vm.Name
    $mode = $state['config']['streaming']['captureMode']; if (-not $mode) { $mode = 'wgc' }
    $null = & $vm.Module { param($n, $g, $m) Set-GuestCaptureMode -Name $n -Credential $g -Mode $m -Restart } $vm.Name $vm.Guest $mode
    & $vm.Module { param($a, $c) Wait-SunshineReady -Address $a -Credential $c -TimeoutSec 120 -Message 'Sunshine' } $vm.Address $vm.Sunshine | Out-Null
    Start-Sleep -Seconds 3
}
function global:Set-Lab041Sunshine($vm, [System.Collections.IDictionary]$Settings) {
    $original = Invoke-Command -VMName $vm.Name -Credential $vm.Guest -ArgumentList ([hashtable]$Settings) -ScriptBlock {
        param($settings)
        $conf = 'C:\Program Files\Sunshine\config\sunshine.conf'
        $before = [IO.File]::ReadAllText($conf)
        $lines = @($before -split "`r?`n" | Where-Object { $_ -and ($_ -split '=')[0].Trim() -notin $settings.Keys })
        foreach ($k in $settings.Keys) { $lines += "$k = $($settings[$k])" }
        [IO.File]::WriteAllLines($conf, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
        $before
    }
    Restart-Lab041Sunshine $vm
    $original
}
function global:Reset-Lab041Sunshine($vm, [string]$Original) {
    if ($null -eq $Original) { return }
    Invoke-Command -VMName $vm.Name -Credential $vm.Guest -ArgumentList $Original -ScriptBlock {
        param($text)
        [IO.File]::WriteAllText('C:\Program Files\Sunshine\config\sunshine.conf', $text, (New-Object Text.UTF8Encoding $false))
    }
    Restart-Lab041Sunshine $vm
}
function New-Lab041SunshineVariant([string]$Name, [System.Collections.IDictionary]$Settings) {
    $keep = @{ original = $null }
    @{ Name = $Name
       Setup = { param($vm) $keep.original = Set-Lab041Sunshine $vm $Settings }.GetNewClosure()
       Undo = { param($vm) Reset-Lab041Sunshine $vm $keep.original; $keep.original = $null }.GetNewClosure() }
}

function Get-Lab041Variants {
    [ordered]@{
        'baseline'   = @{ Name = 'baseline' }
        # NVENC without its quarter-resolution first pass (Sunshine's default is quarter_res).
        'twopass-off' = New-Lab041SunshineVariant 'twopass-off' ([ordered]@{ nvenc_twopass = 'disabled' })
        # Sunshine re-encodes the last picture up to half the client FPS (90) when nothing new comes: fewer of those.
        'minfps-20'  = New-Lab041SunshineVariant 'minfps-20' ([ordered]@{ minimum_fps_target = '20' })
        'sunshine-both' = New-Lab041SunshineVariant 'sunshine-both' ([ordered]@{ nvenc_twopass = 'disabled'; minimum_fps_target = '20' })
        # The picture in a window (composed by DWM, like inside GpuVM's window) with the viewer's frame queue at 3
        # (upstream's default) or 1 (tried Nov 17 through GPUVM_FRAME_LATENCY, rejected: no gain; the viewer no longer reads it).
        'windowed-q3' = @{ Name = 'windowed-q3'; Client = @{ displayMode = 'windowed' }; Setup = { param($vm) $env:GPUVM_FRAME_LATENCY = '3' }; Undo = { param($vm) Remove-Item Env:GPUVM_FRAME_LATENCY -ErrorAction SilentlyContinue } }
        'windowed' = @{ Name = 'windowed'; Client = @{ displayMode = 'windowed' } }
        'app-closed' = @{ Name = 'app-closed'; Setup = { param($vm) Stop-Lab041App }; Undo = { param($vm) Start-Lab041App } }
        'app-home'   = @{ Name = 'app-home'; Setup = { param($vm) Start-Lab041App } }
    }
}
