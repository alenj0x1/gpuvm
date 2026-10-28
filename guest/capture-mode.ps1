# Switches how Sunshine captures the screen. Runs inside the VM as administrator (PowerShell Direct). Windows PowerShell 5.1.
#   ddx: desktop duplication, Sunshine as a service (default). Sees Windows' administrator prompts.
#   wgc: Windows.Graphics.Capture, Sunshine in the signed-in user's session. Sees games in exclusive fullscreen,
#        which ddx cannot capture on a virtual display, but not the administrator prompts (secure desktop).
# Does nothing if it is already in that mode, so opening the VM doesn't restart Sunshine for no reason.
param([Parameter(Mandatory)][ValidateSet('ddx', 'wgc')][string]$Mode)

$exe = 'C:\Program Files\Sunshine\sunshine.exe'
$conf = 'C:\Program Files\Sunshine\config\sunshine.conf'
$task = 'GpuVM-Sunshine-User'
$service = Get-Service | Where-Object { $_.Name -like '*sunshine*' } | Select-Object -First 1
if (-not $service -or -not (Test-Path $exe)) { return 'nosunshine' }

$lines = @(Get-Content -LiteralPath $conf -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '^\s*capture\s*=' })
if ($Mode -eq 'wgc') { $lines += 'capture = wgc' }
$current = (Get-Content -LiteralPath $conf -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*capture\s*=' }) -replace '^\s*capture\s*=\s*', ''
$confChanged = ([string]$current).Trim() -ne $(if ($Mode -eq 'wgc') { 'wgc' } else { '' })
# The service also starts sunshine.exe in the user's session (as SYSTEM), so the user-mode instance is told apart by its task.
$userTask = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue

if ($Mode -eq 'wgc') {
    $ready = -not $confChanged -and $service.Status -ne 'Running' -and $userTask -and $userTask.State -eq 'Running'
    if ($ready) { return 'unchanged' }
    $user = (Get-CimInstance Win32_ComputerSystem).UserName
    if (-not $user) { return 'nosession' }
    if ($confChanged) { [IO.File]::WriteAllLines($conf, [string[]]$lines, (New-Object Text.UTF8Encoding $false)) }
    Stop-Service $service.Name -Force -ErrorAction SilentlyContinue
    Set-Service $service.Name -StartupType Manual
    Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force
    # conhost --headless: Sunshine is a console program; this runs it without a terminal window.
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" -Argument "--headless `"$exe`"" -WorkingDirectory (Split-Path $exe)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries
    Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $task
    return 'changed'
}

$ready = -not $confChanged -and $service.Status -eq 'Running' -and -not $userTask
if ($ready) { return 'unchanged' }
if ($userTask) {
    Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $task -Confirm:$false
    Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force
}
if ($confChanged) { [IO.File]::WriteAllLines($conf, [string[]]$lines, (New-Object Text.UTF8Encoding $false)) }
Set-Service $service.Name -StartupType Automatic
Restart-Service $service.Name -Force
'changed'
