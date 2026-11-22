# Makes Sunshine capture with Windows.Graphics.Capture through the fork's helper (tools\sunshine_wgc_capture.exe),
# which captures as the signed-in user and holds nothing secret. Runs inside the VM as administrator (PowerShell
# Direct). Windows PowerShell 5.1. Sunshine is always the service (SYSTEM), on every machine; GpuVM ships its own
# Sunshine fork for that. Shows the picture at once and games in exclusive fullscreen; administrator prompts (secure
# desktop) are answered from GpuVM's own card. Without the helper Sunshine falls back to desktop duplication (answer
# prefixed "nofork-"), which on the virtual display over GPU-P loses access after every frame (lab 055).
# Machines from before the fork ran Sunshine as the user from a logon task (GpuVM-Sunshine-User): it is removed here,
# and so is a "ddx" choice an older machine kept.
# Does nothing if it already captures that way, so opening the VM doesn't restart Sunshine for no reason.
# -Restart restarts it anyway: after the display changed, so it tests its encoders now instead of when the viewer connects.
param([switch]$Restart)

$exe = 'C:\Program Files\Sunshine\sunshine.exe'
$conf = 'C:\Program Files\Sunshine\config\sunshine.conf'
$task = 'GpuVM-Sunshine-User'
$service = Get-Service | Where-Object { $_.Name -like '*sunshine*' } | Select-Object -First 1
if (-not $service -or -not (Test-Path $exe)) { return 'nosunshine' }

$nofork = -not (Test-Path 'C:\Program Files\Sunshine\tools\sunshine_wgc_capture.exe')
$want = if ($nofork) { '' } else { 'wgc' }
$lines = @(Get-Content -LiteralPath $conf -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '^\s*capture\s*=' })
if ($want) { $lines += "capture = $want" }
$current = (Get-Content -LiteralPath $conf -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*capture\s*=' }) -replace '^\s*capture\s*=\s*', ''
$confChanged = ([string]$current).Trim() -ne $want
$userTask = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue

$prefix = if ($nofork) { 'nofork-' } else { '' }
$ready = -not $confChanged -and $service.Status -eq 'Running' -and -not $userTask
if ($ready -and -not $Restart) { return "${prefix}unchanged" }
if ($userTask) {
    Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $task -Confirm:$false
    Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force
}
if ($confChanged) { [IO.File]::WriteAllLines($conf, [string[]]$lines, (New-Object Text.UTF8Encoding $false)) }
Set-Service $service.Name -StartupType Automatic
Restart-Service $service.Name -Force -WarningAction SilentlyContinue
"${prefix}changed"
