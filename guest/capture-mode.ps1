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
