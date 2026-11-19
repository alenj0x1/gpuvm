# Lab 052 stand-in for guest\agent\install.ps1 (the real one comes from the guest agent's session), with the same
# contract Install-GpuVMAgent uses: runs in the guest as an administrator over PowerShell Direct; the files are in
# $Staging (copied with Copy-VMFile), the secret in C:\ProgramData\GpuVM\Agent\secret. Installs stub052.exe as a
# boot-time SYSTEM task, creates the standard user `agent` with a random password and its Desktop\Outbox, and returns
# {password, version}. -Uninstall removes all of it.
param([string]$Staging, [switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$dir = 'C:\ProgramData\GpuVM\Agent'
$task = 'GpuVMLab052-agent'

function Stop-Stub {
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
    }
    Get-Process stub052 -ErrorAction SilentlyContinue | Stop-Process -Force
}

if ($Uninstall) {
    Stop-Stub
    if (Get-LocalUser -Name agent -ErrorAction SilentlyContinue) { Remove-LocalUser -Name agent }
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    return
}
Stop-Stub
Copy-Item (Join-Path $Staging '*') $dir -Recurse -Force
Remove-Item $Staging -Recurse -Force

# The agent's own standard account (no administrator). A new random password on every install.
$bytes = [byte[]]::new(24); [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$plain = 'Ag7!' + [Convert]::ToBase64String($bytes).Replace('/', 'x').Replace('+', 'y')
$password = ConvertTo-SecureString $plain -AsPlainText -Force
if (Get-LocalUser -Name agent -ErrorAction SilentlyContinue) { Set-LocalUser -Name agent -Password $password }
else { New-LocalUser -Name agent -Password $password -PasswordNeverExpires -AccountNeverExpires -Description 'GpuVM agent' | Out-Null }
# Users group by SID (localized names). The profile folder exists only after a first sign-in; the lab creates the
# Outbox path itself so the stub can serve files from it.
Add-LocalGroupMember -SID 'S-1-5-32-545' -Member agent -ErrorAction SilentlyContinue
$outbox = 'C:\Users\agent\Desktop\Outbox'
New-Item -ItemType Directory -Force $outbox | Out-Null

$action = New-ScheduledTaskAction -Execute (Join-Path $dir 'stub052.exe') -Argument "run --log $dir\stub.log"
$principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings -Trigger (New-ScheduledTaskTrigger -AtStartup) -Force | Out-Null
Start-ScheduledTask -TaskName $task
[pscustomobject]@{ password = $plain; version = 'stub-052' }
