# Lab 026: can a helper in the VM read and answer a Windows administrator prompt on the host's order (the "Permitir /
# Rechazar" buttons in GpuVM, for WGC capture, lab 025)? On the real VM:
#   1. reads the secure desktop with no prompt open;
#   2. raises a prompt (cmd.exe asking to write C:\Windows\lab026-yes.txt, which only an elevated process can) and reads it;
#   3. answers Yes: the file must appear and the prompt close;
#   4. raises it again and answers No: no file, prompt closed.
# Run elevated: pwsh -File labs/026-answer-prompt/run.ps1 -Name win10
param(
    [string]$Name = 'win10',
    [string]$OutDir = (Join-Path $PSScriptRoot "out\$(Get-Date -Format 'yyyyMMdd-HHmmss')")
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$tools = Join-Path $PSScriptRoot '..\..\tools\latency'
. (Join-Path $tools 'common.ps1')
if ((Get-VM -Name $Name).State -ne 'Running') { throw "La VM '$Name' está apagada. Ábrela desde GpuVM." }
$vm = Get-LatencyVM -Name $Name
$session = New-PSSession -VMName $Name -Credential $vm.Guest

$files = @{ helper = Get-Content -Raw (Join-Path $PSScriptRoot 'helper.ps1'); launcher = Get-Content -Raw (Join-Path $PSScriptRoot 'launcher.ps1') }
Invoke-Command -Session $session -ArgumentList $files -ScriptBlock {
    param($files)
    [IO.File]::WriteAllText('C:\GpuVM\lab026-helper.ps1', $files.helper, [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText('C:\GpuVM\lab026-launcher.ps1', $files.launcher, [Text.UTF8Encoding]::new($true))
    Remove-Item C:\Windows\lab026-yes.txt -ErrorAction SilentlyContinue
}

function Invoke-Helper([string]$Action) {
    $started = Get-Date
    $r = Invoke-Command -Session $session -ArgumentList $Action -ScriptBlock {
        param($action)
        Remove-Item C:\GpuVM\lab026-helper.json, C:\GpuVM\lab026-launcher.txt -ErrorAction SilentlyContinue
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\GpuVM\lab026-launcher.ps1 -Action $action"
        Register-ScheduledTask -TaskName GpuVM-Lab026 -Action $a -User SYSTEM -RunLevel Highest -Force | Out-Null
        Start-ScheduledTask GpuVM-Lab026
        for ($i = 0; $i -lt 60 -and -not (Test-Path C:\GpuVM\lab026-launcher.txt); $i++) { Start-Sleep -Milliseconds 500 }
        Unregister-ScheduledTask GpuVM-Lab026 -Confirm:$false
        [pscustomobject]@{
            launcher = Get-Content C:\GpuVM\lab026-launcher.txt -ErrorAction SilentlyContinue
            helper = Get-Content -Raw C:\GpuVM\lab026-helper.json -ErrorAction SilentlyContinue
        }
    }
    [pscustomobject]@{ action = $Action; seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1); launcher = $r.launcher; helper = $r.helper }
}

function Open-Prompt {
    Invoke-Command -Session $session -ScriptBlock {
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        Set-Content C:\GpuVM\lab026-prompt.ps1 "Start-Process cmd.exe -ArgumentList '/c echo ok > C:\Windows\lab026-yes.txt' -Verb RunAs" -Encoding UTF8
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\GpuVM\lab026-prompt.ps1'
        Register-ScheduledTask -TaskName GpuVM-Lab026Prompt -Action $a -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
        Start-ScheduledTask GpuVM-Lab026Prompt
        for ($i = 0; $i -lt 20 -and -not (Get-Process consent -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
        Start-Sleep -Seconds 1
        Unregister-ScheduledTask GpuVM-Lab026Prompt -Confirm:$false
        [bool](Get-Process consent -ErrorAction SilentlyContinue)
    }
}

function Get-Outcome {
    Invoke-Command -Session $session -ScriptBlock {
        Start-Sleep -Seconds 3
        [pscustomobject]@{ promptOpen = [bool](Get-Process consent -ErrorAction SilentlyContinue); elevatedRan = Test-Path C:\Windows\lab026-yes.txt }
    }
}

$steps = [System.Collections.Generic.List[object]]::new()
try {
    $steps.Add((Invoke-Helper 'read')); "1 no prompt: $($steps[-1] | ConvertTo-Json -Compress -Depth 4)" | Write-Host
    "prompt open: $(Open-Prompt)" | Write-Host
    $steps.Add((Invoke-Helper 'read')); "2 prompt: $($steps[-1] | ConvertTo-Json -Compress -Depth 4)" | Write-Host
    $steps.Add((Invoke-Helper 'yes')); $o = Get-Outcome; $steps[-1] | Add-Member outcome $o
    "3 yes: $($steps[-1] | ConvertTo-Json -Compress -Depth 4)" | Write-Host
    Invoke-Command -Session $session -ScriptBlock { Remove-Item C:\Windows\lab026-yes.txt -ErrorAction SilentlyContinue }
    "prompt open: $(Open-Prompt)" | Write-Host
    $steps.Add((Invoke-Helper 'no')); $o = Get-Outcome; $steps[-1] | Add-Member outcome $o
    "4 no: $($steps[-1] | ConvertTo-Json -Compress -Depth 4)" | Write-Host
}
finally {
    Invoke-Command -Session $session -ScriptBlock {
        Get-Process consent -ErrorAction SilentlyContinue | Stop-Process -Force
        foreach ($t in 'GpuVM-Lab026', 'GpuVM-Lab026Prompt') { Unregister-ScheduledTask $t -Confirm:$false -ErrorAction SilentlyContinue }
        Remove-Item C:\GpuVM\lab026-*, C:\Windows\lab026-yes.txt -ErrorAction SilentlyContinue
    }
    Remove-PSSession $session
    @($steps) | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutDir 'result.json') -Encoding utf8
    "saved $OutDir" | Write-Host
}
