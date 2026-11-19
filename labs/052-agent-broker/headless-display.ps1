# Lab 052: a copy of agent-tpl has a screen for its agent without any viewer (agent-guest 2026-11-19: displays []
# with the Hyper-V display disabled). This branch's module (installed agent package and viewer, read-only): makes the
# copy, starts it, records the Hyper-V display's state, installs the agent (as a claim does), then asks the agent for
# agent.info and a screenshot with no viewer anywhere; finally Connect-GpuVM -Viewer prepares the stream and the agent
# is asked again. The copy (3 GB) is deleted at the end. Under the shared lab lock. Run elevated.
param([string]$Template = 'agent-tpl', [string]$Name = 'agent052h', [string]$Session = 'agent-broker', [int]$AgentWaitSec = 240)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$module = Join-Path $root 'src\GpuVM\GpuVM.psd1'
$installed = Join-Path $env:ProgramFiles 'GpuVM\gpuvm'
function Line($what) { Write-Host "$(Get-Date -Format HH:mm:ss.fff) $what" }
$result = [ordered]@{ module = "$(git -C $root rev-parse --short HEAD)" }
& (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What "lab 052: headless display on a copy of $Template" -Me $Session -MaxMinutes 120
if ($LASTEXITCODE) { throw 'no lock' }
$made = $false
try {
    Import-Module $module -Force
    $m = Get-Module GpuVM
    & $m {
        param($viewer, $dist)
        $script:LabViewer = $viewer; $script:LabDist = $dist
        function script:Get-GpuVMViewerPath { $script:LabViewer }
        function script:Get-RepoPath { param($Relative) if ($Relative -eq 'guest\agent') { $script:LabDist } else { Join-Path $script:RepoRoot $Relative } }
    } (Join-Path $installed 'viewer\GpuVMViewer.exe') (Join-Path $installed 'guest\agent')
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false }
    New-GpuVM -Name $Name -Template $Template | Out-Null
    $made = $true
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes 3GB
    Start-VM -Name $Name
    $t0 = Get-Date
    $state = & $m { param($n) Get-GpuVMState -Name $n } $Name
    $result['use'] = $state['use']
    $result['disableHyperVVideo'] = $state['config']['streaming']['disableHyperVVideo']
    $cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
    & $m { param($n, $c) Wait-GuestReady -Name $n -Credential $c } $Name $cred
    $video = { @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FriendlyName): $($_.Status)" }) }
    $result['displaysBefore'] = @(Invoke-Command -VMName $Name -Credential $cred $video)
    Line "display adapters before: $($result['displaysBefore'] -join '; ')"
    $result['install'] = Install-GpuVMAgent -Name $Name
    Line "installed: $($result['install'] | ConvertTo-Json -Compress -Depth 3)"
    if ($result['install'].restarted) { & $m { param($n, $c) Start-Sleep 20; Wait-GuestReady -Name $n -Credential $c } $Name $cred }
    $result['displaysAfter'] = @(Invoke-Command -VMName $Name -Credential $cred $video)
    Line "display adapters after: $($result['displaysAfter'] -join '; ')"
    # No viewer anywhere: the agent's own view of its screen.
    $result['viewersRunning'] = @(Get-Process GpuVMViewer, Moonlight -ErrorAction SilentlyContinue).Count
    $w = [Diagnostics.Stopwatch]::StartNew()
    $info = $null
    while ($w.Elapsed.TotalSeconds -lt $AgentWaitSec) {
        $info = try { Invoke-GpuVMAgent -Name $Name -Method agent.info -TimeoutSec 10 } catch { $null }
        if ($info -and $info.ok -and @($info.result.displays).Count) { break }
        Start-Sleep -Seconds 3
    }
    $result['agentInfoSec'] = [math]::Round(((Get-Date) - $t0).TotalSeconds)
    $result['agentInfo'] = $info
    Line "agent.info after $($result['agentInfoSec']) s: displays $(@($info.result.displays) | ConvertTo-Json -Compress -Depth 4)"
    $shot = try { Invoke-GpuVMAgent -Name $Name -Method screen.capture -Params @{ maxW = 640 } -TimeoutSec 20 } catch { [pscustomobject]@{ ok = $false; error = "$_" } }
    $result['capture'] = [ordered]@{ ok = $shot.ok; error = $shot.error; result = $shot.result; blobBytes = $shot.blobBytes; blobPath = $shot.blobPath }
    if ($shot.blobPath -and (Test-Path $shot.blobPath)) { Copy-Item $shot.blobPath (Join-Path $out "headless-$stamp.$($shot.blobFormat)") }
    Line "screen.capture without a viewer: ok=$($shot.ok) bytes=$($shot.blobBytes) $($shot.error | ConvertTo-Json -Compress)"
    # The stream is still prepared as before.
    $connect = Connect-GpuVM -Name $Name -Viewer 3>&1
    $result['connect'] = @($connect | ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord]) { "WARN $($_.Message)" } else { $_ | ConvertTo-Json -Compress -Depth 4 } })
    Line "Connect-GpuVM -Viewer: $($result['connect'] -join ' | ')"
    $again = try { Invoke-GpuVMAgent -Name $Name -Method agent.info -TimeoutSec 10 } catch { $null }
    $result['agentInfoAfterConnect'] = @($again.result.displays)
    Line "agent.info after Connect: displays $(@($again.result.displays) | ConvertTo-Json -Compress -Depth 4)"
}
catch { $result['error'] = "$($_.Exception.Message)"; Line "ERROR $($result['error'])" }
finally {
    if ($made) {
        try { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false; Line "$Name deleted" }
        catch { Line "couldn't delete $Name : $($_.Exception.Message)" }
    }
    $result | ConvertTo-Json -Depth 7 | Set-Content (Join-Path $out "headless-display-$stamp.json") -Encoding utf8
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Line 'lock released'
}
