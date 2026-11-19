# Lab 052: what the app's "Open" does on a copy of agent-tpl (Connect-GpuVM -Viewer, the installed module), step by
# step with timestamps, to see where "Waiting for Sunshine" comes from. The copy runs on 3 GB (Hyper-V only) and is
# deleted at the end; nothing installed is touched. Under the shared lab lock. Run elevated.
param([string]$Template = 'agent-tpl', [string]$Name = 'agent052c', [string]$Session = 'agent-broker', [int]$LimitSec = 420)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$module = Join-Path $env:ProgramFiles 'GpuVM\gpuvm\src\GpuVM\GpuVM.psd1'
function Line($what) { Write-Host "$(Get-Date -Format HH:mm:ss.fff) $what" }
& (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What "lab 052: Connect-GpuVM on a copy of $Template" -Me $Session -MaxMinutes 120
if ($LASTEXITCODE) { throw 'no lock' }
$made = $false
$result = [ordered]@{}
try {
    Import-Module $module -Force
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false }
    New-GpuVM -Name $Name -Template $Template | Out-Null
    $made = $true
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes 3GB
    Start-VM -Name $Name
    $t0 = Get-Date
    Line 'copy started; Connect-GpuVM -Viewer (what Open runs) in a job, with every step it reports'
    $job = Start-ThreadJob -ArgumentList $module, $Name {
        param($m, $n)
        Import-Module $m -Force
        $global:GpuVMProgressSink = { param($message) Write-Output "STEP $(Get-Date -Format HH:mm:ss.fff) $message" }
        try { $r = Connect-GpuVM -Name $n -Viewer 3>&1; $r | ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord]) { "WARN $(Get-Date -Format HH:mm:ss.fff) $($_.Message)" } else { "RESULT $($_ | ConvertTo-Json -Compress -Depth 4)" } } }
        catch { "ERROR $(Get-Date -Format HH:mm:ss.fff) $($_.Exception.Message)" }
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    while ($job.State -eq 'Running' -and ((Get-Date) - $t0).TotalSeconds -lt $LimitSec) {
        foreach ($l in @(Receive-Job $job)) { $lines.Add("$l"); Line "$l" }
        Start-Sleep -Seconds 2
    }
    foreach ($l in @(Receive-Job $job)) { $lines.Add("$l"); Line "$l" }
    $result['finished'] = $job.State -ne 'Running'
    $result['seconds'] = [math]::Round(((Get-Date) - $t0).TotalSeconds)
    $result['lines'] = @($lines)
    if ($job.State -eq 'Running') { Stop-Job $job; Line "Connect-GpuVM still running after $LimitSec s: stopped" }
    # Where things are when it's done or stuck.
    $m = Get-Module GpuVM
    $state = & $m { param($n) Get-GpuVMState -Name $n } $Name
    $cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
    $result['pendingRename'] = $state['pendingRename']
    $result['guest'] = Invoke-Command -VMName $Name -Credential $cred {
        [ordered]@{ computer = $env:COMPUTERNAME; console = (Get-CimInstance Win32_ComputerSystem).UserName
            sunshine = "$((Get-Service SunshineService -ErrorAction SilentlyContinue).Status)"
            bootedAt = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')
            displays = @(Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name): $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution) $($_.Status)" })
            logTail = @(Get-Content 'C:\Program Files\Sunshine\config\sunshine.log' -Tail 25 -ErrorAction SilentlyContinue) }
    }
    Line "guest now: $($result['guest'] | ConvertTo-Json -Compress -Depth 3)"
}
finally {
    if ($made) {
        try { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false; Line "$Name deleted" }
        catch { Line "couldn't delete $Name : $($_.Exception.Message)" }
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out "connect-clone-$stamp.json") -Encoding utf8
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Line 'lock released'
}
