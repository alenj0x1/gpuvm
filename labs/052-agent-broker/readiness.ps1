# Lab 052: readiness of a copy of agent-tpl (the 30-minute wait for setup.done.json). This checkout's module (not
# the installed one, and no installed file is touched) makes a copy of the template, then times Wait-GuestReady and
# Install-GpuVMAgent (which now waits for the first-time setup first), against the installed GpuVM service. The copy
# is deleted at the end. Under the shared lab lock. Run elevated.
param([string]$Template = 'agent-tpl', [string]$Name = 'agent052r', [string]$Session = 'agent-broker')
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'
$result = [ordered]@{}
function Line($what) { Write-Host "$(Get-Date -Format HH:mm:ss) $what" }
& (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What "lab 052: readiness of a copy of $Template" -Me $Session -MaxMinutes 120
if ($LASTEXITCODE) { throw 'no lock' }
$made = $false
try {
    Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
    $module = Get-Module GpuVM
    $w = [Diagnostics.Stopwatch]::StartNew()
    New-GpuVM -Name $Name -Template $Template | Out-Null
    $made = $true
    # 2 GB in Hyper-V only (GpuVM asks 4; this lab VM is deleted at the end).
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes 2GB
    Start-VM -Name $Name
    $result['createdAndStartedMs'] = [math]::Round($w.Elapsed.TotalMilliseconds)
    $cred = & $module { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $Name
    $w.Restart()
    while ($w.Elapsed.TotalMinutes -lt 10) { try { Invoke-Command -VMName $Name -Credential $cred { 1 } -ErrorAction Stop | Out-Null; break } catch { Start-Sleep -Milliseconds 500 } }
    $result['psDirectMs'] = [math]::Round($w.Elapsed.TotalMilliseconds)
    $result['copyState'] = Invoke-Command -VMName $Name -Credential $cred {
        $winlogon = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        $done = 'C:\GpuVM\setup.done.json'
        [ordered]@{ setupDone = Test-Path $done; setupDoneContent = if (Test-Path $done) { (Get-Content -Raw $done | ConvertFrom-Json).finishedAt } else { $null }
            setupLog = Test-Path 'C:\GpuVM\setup.log'; autoLogonUser = $winlogon.DefaultUserName; consoleUser = (Get-CimInstance Win32_ComputerSystem).UserName
            agentService = (Get-Service GpuVMAgent -ErrorAction SilentlyContinue).Status }
    }
    Line "copy: $($result['copyState'] | ConvertTo-Json -Compress)"
    # The wait New-GpuVM -Use agent and Connect-GpuVM do (with the fix: it ends when the agent is signed in).
    $w.Restart()
    $warnings = @()
    & $module { param($n, $c) Wait-GuestReady -Name $n -Credential $c -TimeoutSec 600 } $Name $cred -WarningVariable +warnings
    $result['waitGuestReadyMs'] = [math]::Round($w.Elapsed.TotalMilliseconds)
    $result['waitWarnings'] = @($warnings | ForEach-Object { "$_" })
    Line "Wait-GuestReady: $($result['waitGuestReadyMs']) ms; warnings: $($result['waitWarnings'] -join ' | ')"
    $w.Restart()
    $install = Install-GpuVMAgent -Name $Name
    $result['install'] = $install
    $result['installMs'] = [math]::Round($w.Elapsed.TotalMilliseconds)
    $w.Restart()
    $state = $null
    while ($w.Elapsed.TotalSeconds -lt 120) { $state = @(Get-GpuVMAgent -Name $Name)[0].state; if ($state -eq 'ready') { break }; Start-Sleep -Milliseconds 200 }
    $result['agentState'] = $state
    $result['agentReadyAfterInstallMs'] = [math]::Round($w.Elapsed.TotalMilliseconds)
    Line "install: $($install | ConvertTo-Json -Compress -Depth 4); agent $state after $($result['agentReadyAfterInstallMs']) ms"
}
finally {
    if ($made) {
        try { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false; Line "$Name deleted" }
        catch { Line "couldn't delete $Name : $($_.Exception.Message)" }
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out "readiness-$(Get-Date -Format yyyyMMdd-HHmmss).json") -Encoding utf8
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Line 'lock released'
}
