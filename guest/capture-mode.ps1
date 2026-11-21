# Switches how Sunshine captures the screen. Runs inside the VM as administrator (PowerShell Direct). Windows PowerShell 5.1.
# Sunshine is always the service (SYSTEM), on every machine; GpuVM ships its own Sunshine fork for that.
#   wgc (default): Windows.Graphics.Capture through the fork's helper (tools\sunshine_wgc_capture.exe), which captures
#        as the signed-in user and holds nothing secret. Shows the picture at once and games in exclusive fullscreen;
#        administrator prompts (secure desktop) are answered from GpuVM's own card. Without the helper it is ddx
#        (answer prefixed "nofork-").
#   ddx: desktop duplication. Streams administrator prompts, but on the virtual display over GPU-P it loses access
#        after every frame (lab 055): the picture can stay black.
# Machines from before the fork ran Sunshine as the user from a logon task (GpuVM-Sunshine-User): it is removed here.
# Does nothing if it is already in that mode, so opening the VM doesn't restart Sunshine for no reason.
# -Restart restarts it anyway: after the display changed, so it tests its encoders now instead of when Moonlight connects.
param([Parameter(Mandatory)][ValidateSet('ddx', 'wgc')][string]$Mode, [switch]$Restart)

$exe = 'C:\Program Files\Sunshine\sunshine.exe'
$conf = 'C:\Program Files\Sunshine\config\sunshine.conf'
$task = 'GpuVM-Sunshine-User'
$service = Get-Service | Where-Object { $_.Name -like '*sunshine*' } | Select-Object -First 1
if (-not $service -or -not (Test-Path $exe)) { return 'nosunshine' }

$nofork = $false
if ($Mode -eq 'wgc' -and -not (Test-Path 'C:\Program Files\Sunshine\tools\sunshine_wgc_capture.exe')) { $Mode = 'ddx'; $nofork = $true }
$want = if ($Mode -eq 'wgc') { 'wgc' } else { '' }
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
Restart-Service $service.Name -Force
"${prefix}changed"
