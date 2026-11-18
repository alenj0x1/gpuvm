# Lab 042 helper: opens a harmless administrator prompt in the guest (cmd.exe /c exit, run as administrator by the
# signed-in user), as a person would get one. Answer it from GpuVM (or -Deny here, through the module).
# Run elevated: pwsh -File labs/042-admin-dock/raise-prompt.ps1 -Name win-gpu [-Deny]
param([string]$Name = 'win-gpu', [switch]$Deny)
$ErrorActionPreference = 'Stop'
$m = Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force -PassThru -DisableNameChecking
if ($Deny) {
    $p = & $m { param($n) Get-GuestAdminPromptState -Name $n } $Name
    if ($p) { Resolve-GpuVMAdminPrompt -Name $Name -Answer Deny -PromptId $p.id | Out-Null; "denied $($p.id)" } else { 'no prompt' }
    return
}
$guest = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $Name
Invoke-Command -VMName $Name -Credential $guest -ScriptBlock {
    $user = (Get-CimInstance Win32_ComputerSystem).UserName
    $script = 'C:\Users\Public\gpuvm-lab042-raise.ps1'
    Set-Content $script "Start-Process cmd.exe -ArgumentList '/c exit' -Verb RunAs" -Encoding UTF8
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $script"
    Register-ScheduledTask -TaskName GpuVM-Lab042Raise -Action $a -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
    Start-ScheduledTask GpuVM-Lab042Raise
    for ($i = 0; $i -lt 100 -and -not (Get-Process consent -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 50 }
    Unregister-ScheduledTask GpuVM-Lab042Raise -Confirm:$false
    Remove-Item $script -ErrorAction SilentlyContinue
    "prompt open: $([bool](Get-Process consent -ErrorAction SilentlyContinue))"
}
