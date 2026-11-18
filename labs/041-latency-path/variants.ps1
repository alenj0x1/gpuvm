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

function Get-Lab041Variants {
    [ordered]@{
        'baseline'   = @{ Name = 'baseline' }
        'app-closed' = @{ Name = 'app-closed'; Setup = { param($vm) Stop-Lab041App }; Undo = { param($vm) Start-Lab041App } }
        'app-home'   = @{ Name = 'app-home'; Setup = { param($vm) Start-Lab041App } }
    }
}
