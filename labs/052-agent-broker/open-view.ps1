# Lab 052: the MCP server's open_viewer on a fresh copy of agent-tpl, exactly as the demo does it: the installed
# build, `gpuvm.exe --view <copy>` while GpuVM runs (the app runs Connect-GpuVM -Viewer and opens its viewer). Follows
# GpuVM's viewer processes and their logs (%TEMP%\Moonlight-*.log), then reads Sunshine's log and state in the guest.
# The app shows itself during the run. The copy (3 GB) is deleted at the end. Under the shared lab lock. Run elevated.
param([string]$Template = 'agent-tpl', [string]$Name = 'agent052v', [string]$Session = 'agent-broker', [int]$WatchSec = 300)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$installed = Join-Path $env:ProgramFiles 'GpuVM'
$module = Join-Path $installed 'gpuvm\src\GpuVM\GpuVM.psd1'
$app = Join-Path $installed 'gpuvm.exe'
function Line($what) { Write-Host "$(Get-Date -Format HH:mm:ss.fff) $what" }
if (-not (Get-Process gpuvm -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $app })) { throw 'GpuVM (the app) is not running: open_viewer needs it.' }
$theirs = @(Get-Process GpuVMViewer -ErrorAction SilentlyContinue | ForEach-Object Id)
& (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What "lab 052: open_viewer on a copy of $Template" -Me $Session -MaxMinutes 120
if ($LASTEXITCODE) { throw 'no lock' }
$made = $false
$result = [ordered]@{ events = [System.Collections.Generic.List[string]]::new() }
function Note($what) { $result['events'].Add("$(Get-Date -Format HH:mm:ss.fff) $what"); Line $what }
try {
    Import-Module $module -Force
    $m = Get-Module GpuVM
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false }
    New-GpuVM -Name $Name -Template $Template | Out-Null
    $made = $true
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes 3GB
    Start-VM -Name $Name
    $t0 = Get-Date
    Note "copy started; gpuvm.exe --view $Name"
    & $m { param($f, $a) Start-UnelevatedProcess -FilePath $f -ArgumentList $a } $app @('--view', $Name) | Out-Null
    $seen = @{}
    while (((Get-Date) - $t0).TotalSeconds -lt $WatchSec) {
        foreach ($p in @(Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Where-Object { $_.Id -notin $theirs })) {
            if (-not $seen.ContainsKey($p.Id)) { $seen[$p.Id] = $p; Note "viewer $($p.Id) started" }
        }
        foreach ($id in @($seen.Keys)) {
            if ($seen[$id] -and -not (Get-Process -Id $id -ErrorAction SilentlyContinue)) { Note "viewer $id ended"; $seen[$id] = $null }
        }
        Start-Sleep -Milliseconds 500
    }
    # The viewer writes its logs under LocalLow (it runs at Low integrity); a plain Moonlight in %TEMP%.
    $logDirs = @((Join-Path $env:USERPROFILE 'AppData\LocalLow\GpuVM\Viewer\logs'), $env:TEMP) | Where-Object { Test-Path $_ }
    $result['viewerLogs'] = @(Get-ChildItem $logDirs -Filter 'Moonlight-*.log' | Where-Object LastWriteTime -ge $t0 | Sort-Object LastWriteTime | ForEach-Object {
            [ordered]@{ file = $_.Name; lines = @(Get-Content $_.FullName | Where-Object { $_ -notmatch 'Qt Warning: qrc|gamepad mappings|Interface ' } | Select-Object -Last 60) } })
    foreach ($log in $result['viewerLogs']) { Note "log $($log.file):"; $log.lines | Select-Object -Last 25 | ForEach-Object { Line "    $_" } }
    $state = & $m { param($n) Get-GpuVMState -Name $n } $Name
    $cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
    $result['guest'] = Invoke-Command -VMName $Name -Credential $cred -ErrorAction Continue {
        [ordered]@{
            console = (Get-CimInstance Win32_ComputerSystem).UserName
            processes = @(Get-CimInstance Win32_Process -Filter "Name='sunshine.exe'" | ForEach-Object { $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner; "session $($_.SessionId) $($o.Domain)\$($o.User) since $($_.CreationDate.ToString('HH:mm:ss'))" })
            service = "$((Get-Service SunshineService).Status)"
            capture = @(Get-Content 'C:\Program Files\Sunshine\config\sunshine.conf' | Where-Object { $_ -match '^\s*(capture|output_name|dd_)' })
            restarts = @(Get-Content 'C:\Program Files\Sunshine\config\sunshine.log' | Where-Object { $_ -match 'Interrupt handler called|Sunshine version|CLIENT CONNECTED|CLIENT DISCONNECTED|Executing|Error|pair|PIN|certificate|cert' } | Select-Object -Last 60)
            # Who Sunshine has paired, and its identity (a copy gets a new one).
            paired = @(try { ((Get-Content -Raw 'C:\Program Files\Sunshine\config\sunshine_state.json' | ConvertFrom-Json).root.named_devices) | ForEach-Object { $_.name } } catch { 'unreadable' })
            certAt = (Get-Item 'C:\Program Files\Sunshine\config\credentials\cacert.pem' -ErrorAction SilentlyContinue).LastWriteTime.ToString('HH:mm:ss')
        }
    }
    Line "guest: $($result['guest'] | ConvertTo-Json -Compress -Depth 3)"
}
catch { $result['error'] = "$($_.Exception.Message)"; Line "ERROR $($result['error'])" }
finally {
    Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Where-Object { $_.Id -notin $theirs } | Stop-Process -Force -ErrorAction SilentlyContinue
    if ($made) {
        try { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false; Line "$Name deleted" }
        catch { Line "couldn't delete $Name : $($_.Exception.Message)" }
    }
    $result['events'] = @($result['events'])
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out "open-view-$stamp.json") -Encoding utf8
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Line 'lock released'
}
