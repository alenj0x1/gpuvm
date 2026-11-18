# Lab 042, part 3: can a guest program WITHOUT elevation forge an answer? It runs, as the signed-in user with a limited
# token, a script that tries to write the host's key (HKLM\SOFTWARE\Microsoft\Virtual Machine\External) and the
# guest's published prompt (...\Guest), and reports what happened. Both must be denied. Cleans up after itself.
# Run elevated: pwsh -File labs/042-admin-dock/forge.ps1 -Name win-gpu
param([string]$Name = 'win-gpu')
$ErrorActionPreference = 'Stop'
$m = Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force -PassThru -DisableNameChecking
$guest = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $Name
$probe = @'
$out = 'C:\Users\Public\gpuvm-lab042-forge.txt'
$lines = @("whoami: $(whoami)", "elevated: $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))")
foreach ($k in 'External', 'Guest') {
    try {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Virtual Machine\$k" -Name GpuVMLab042Forge -Value 'forged' -Type String -ErrorAction Stop
        $lines += "${k}: WROTE"
    }
    catch { $lines += "${k}: denied ($($_.Exception.GetType().Name))" }
}
$lines | Set-Content $out
'@
Invoke-Command -VMName $Name -Credential $guest -ArgumentList $probe -ScriptBlock {
    param($probe)
    $script = 'C:\Users\Public\gpuvm-lab042-forge.ps1'
    $out = 'C:\Users\Public\gpuvm-lab042-forge.txt'
    Remove-Item $out -ErrorAction SilentlyContinue
    Set-Content $script $probe -Encoding UTF8
    $user = (Get-CimInstance Win32_ComputerSystem).UserName
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $script"
    Register-ScheduledTask -TaskName GpuVM-Lab042Forge -Action $a -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
    Start-ScheduledTask GpuVM-Lab042Forge
    for ($i = 0; $i -lt 60 -and -not (Test-Path $out); $i++) { Start-Sleep -Milliseconds 250 }
    Unregister-ScheduledTask GpuVM-Lab042Forge -Confirm:$false
    Get-Content $out -ErrorAction SilentlyContinue
    foreach ($k in 'External', 'Guest') { Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Virtual Machine\$k" -Name GpuVMLab042Forge -ErrorAction SilentlyContinue }
    Remove-Item $script, $out -ErrorAction SilentlyContinue
}
