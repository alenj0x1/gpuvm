# Lab 026, end to end with GpuVM's own code: installs the guest watcher (Install-GuestAdminPrompt), raises a prompt,
# times how long Get-GpuVMAdminPrompt takes to list it, answers Allow through Resolve-GpuVMAdminPrompt (the prompt must
# close and the program run), then raises another, checks that an answer for an old prompt id is refused, and Deny.
# Leaves the watcher installed (as GpuVM will). Run elevated: pwsh -File labs/026-answer-prompt/e2e.ps1 -Name win10
param([string]$Name = 'win10')
$ErrorActionPreference = 'Stop'
$m = Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force -PassThru
$guest = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $Name
"installed: $(& $m { param($n, $c) Install-GuestAdminPrompt -Name $n -Credential $c } $Name $guest)" | Write-Host
Start-Sleep -Seconds 3

function Open-Prompt {
    Invoke-Command -VMName $Name -Credential $guest -ScriptBlock {
        Remove-Item C:\Windows\lab026-yes.txt -ErrorAction SilentlyContinue
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        Set-Content C:\GpuVM\lab026-prompt.ps1 "Start-Process cmd.exe -ArgumentList '/c echo ok > C:\Windows\lab026-yes.txt' -Verb RunAs" -Encoding UTF8
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\GpuVM\lab026-prompt.ps1'
        Register-ScheduledTask -TaskName GpuVM-Lab026Prompt -Action $a -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
        Start-ScheduledTask GpuVM-Lab026Prompt
        Start-Sleep -Seconds 1
        Unregister-ScheduledTask GpuVM-Lab026Prompt -Confirm:$false
    }
    $t = Get-Date
    for ($i = 0; $i -lt 40; $i++) {
        # Straight from the data exchange: Get-GpuVMAdminPrompt only lists VMs captured with WGC (win10 uses DDX).
        $p = @(& $m { param($n) Get-GuestAdminPrompt -Name $n } $Name)
        if ($p) { "listed after $([math]::Round(((Get-Date) - $t).TotalSeconds, 1)) s: $($p[0] | ConvertTo-Json -Compress)" | Write-Host; return $p[0] }
        Start-Sleep -Milliseconds 500
    }
    throw 'The prompt was never listed.'
}
function Get-Outcome {
    Start-Sleep -Seconds 3
    Invoke-Command -VMName $Name -Credential $guest -ScriptBlock { "prompt open: $([bool](Get-Process consent -ErrorAction SilentlyContinue)); program ran: $(Test-Path C:\Windows\lab026-yes.txt)" }
}

try {
    $p = Open-Prompt
    $t = Get-Date; Resolve-GpuVMAdminPrompt -Name $Name -Answer Allow -PromptId $p.id | Out-Null
    "allow answered in $([math]::Round(((Get-Date) - $t).TotalSeconds, 1)) s; $(Get-Outcome)" | Write-Host
    $p = Open-Prompt
    try { Resolve-GpuVMAdminPrompt -Name $Name -Answer Allow -PromptId ($p.id + 1) | Out-Null; 'old id: ANSWERED (wrong)' | Write-Host }
    catch { "old id refused: $($_.Exception.Message)" | Write-Host }
    $t = Get-Date; Resolve-GpuVMAdminPrompt -Name $Name -Answer Deny -PromptId $p.id | Out-Null
    "deny answered in $([math]::Round(((Get-Date) - $t).TotalSeconds, 1)) s; $(Get-Outcome)" | Write-Host
    Start-Sleep -Seconds 3
    "listed after answering: $(@(& $m { param($n) Get-GuestAdminPrompt -Name $n } $Name).Count)" | Write-Host
}
finally {
    Invoke-Command -VMName $Name -Credential $guest -ScriptBlock {
        Get-Process consent -ErrorAction SilentlyContinue | Stop-Process -Force
        Remove-Item C:\GpuVM\lab026-prompt.ps1, C:\Windows\lab026-yes.txt -ErrorAction SilentlyContinue
    }
}
