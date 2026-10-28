# Removes everything lab-b.ps1 added to the VM: detaches the speaker, stops the server task and uninstalls usbip-win2.
# Elevated, PowerShell 7: pwsh -File labs\012-usb-audio-over-usbip\lab-b-revert.ps1
param([string]$Name = (Get-VM | Where-Object Notes -like "Creada con GpuVM*" | Select-Object -First 1).Name)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$module = Get-Module GpuVM
$state = & $module { param($n) Get-GpuVMState -Name $n } $Name
$guest = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state
Invoke-Command -VMName $Name -Credential $guest -ScriptBlock {
    $usbipExe = Get-ChildItem "$env:ProgramFiles\USBip*" -Recurse -Filter usbip.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if ($usbipExe) { & $usbipExe detach --all 2>&1 | Out-Null }
    Stop-ScheduledTask -TaskName 'GpuVM-Lab012-UAC' -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'GpuVM-Lab012-UAC' -Confirm:$false -ErrorAction SilentlyContinue
    $uninstaller = Get-ChildItem "$env:ProgramFiles\USBip" -Filter 'unins*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($uninstaller) { Start-Process $uninstaller.FullName -Wait -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' }
    Remove-Item 'C:\GpuVM\lab012' -Recurse -Force -ErrorAction SilentlyContinue
    'usbip-win2 desinstalado; la VM pide reiniciarse para terminar de quitar los drivers.'
}
