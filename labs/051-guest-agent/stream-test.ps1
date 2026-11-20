# StreamMode (agent 0.4.6): does the agent put the virtual display in the stream's mode before it says hello, from a
# cold start, and keep it? On a copy of agent-tpl made the claim way: Install-GpuVMAgent, then guest/agent/dist installed
# with -StreamMode <mode>, then a cold stop + start (the no-display fix), then agent.info (streamMode wanted/current,
# displays) as soon as the agent answers, again 20 s later (nothing changed it back), and the agent log lines about
# the mode. One round per -Modes entry, one lab lock; the copy is deleted.
param([string]$Template = 'agent-tpl', [string[]]$Modes = @('1920x1080@60', '1920x1080@180'), [string]$Me = 'agent-guest')
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
$m = Get-Module GpuVM
function Step($t) { "[$(Get-Date -Format HH:mm:ss)] $t" | Out-Host }
function Info([string]$n) { try { (Invoke-GpuVMAgent -Name $n -Method agent.info -TimeoutSec 5).result } catch { $null } }
function Show($x) { "agent $($x.version); streamMode $($x.streamMode | ConvertTo-Json -Compress); displays $(@($x.displays | ForEach-Object { "$($_.adapter) $($_.rect -join ',')" }) -join ' | '); noDisplay $($x.noDisplay)" }
$name = 'a051s'
$installer = Get-Content (Join-Path $repo 'guest\agent\install.ps1') -Raw
& (Join-Path $repo 'labs\042-admin-dock\take-lock.ps1') -What "lab 051: StreamMode on a copy of $Template" -Me $Me -MaxMinutes 120
if ($LASTEXITCODE -ne 0) { throw 'no lock' }
try {
    New-GpuVM -Name $name -Template $Template | Out-Null
    Set-VMMemory -VMName $name -DynamicMemoryEnabled $false -StartupBytes 3GB
    Start-VM -Name $name
    $gc = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $name
    & $m { param($n, $cr) Wait-GuestReady -Name $n -Credential $cr } $name $gc
    Install-GpuVMAgent -Name $name | Out-Null
    foreach ($mode in $Modes) {
        & $m { param($n, $cr) Wait-GuestReady -Name $n -Credential $cr } $name $gc
        $s = New-PSSession -VMName $name -Credential $gc
        $staging = 'C:\ProgramData\GpuVM\Agent\staging'
        Invoke-Command -Session $s { param($d) New-Item -ItemType Directory $d -Force | Out-Null } -ArgumentList $staging
        Get-ChildItem (Join-Path $repo 'guest\agent\dist') | ForEach-Object { Copy-Item $_.FullName -Destination $staging -ToSession $s -Force }
        $r = Invoke-Command -Session $s -ScriptBlock ([scriptblock]::Create("& { $installer } -Staging '$staging' -StreamMode '$mode'"))
        Remove-PSSession $s
        Step "[$mode] installed $($r.version) (fast path $($r.fastPath)), recorded streamMode $($r.streamMode)"
        Stop-VM -Name $name -Force
        Start-VM -Name $name
        $sw = [Diagnostics.Stopwatch]::StartNew(); $i = $null
        do { Start-Sleep -Milliseconds 500; $i = Info $name } until (($i -and $i.signedIn -and $i.streamMode) -or $sw.Elapsed.TotalSeconds -gt 120)
        Step "[$mode] first answer after $([math]::Round($sw.Elapsed.TotalSeconds)) s: $(Show $i)"
        Start-Sleep -Seconds 20
        Step "[$mode] 20 s later: $(Show (Info $name))"
        $log = Invoke-Command -VMName $name -Credential $gc { Get-Content C:\ProgramData\GpuVM\Agent\logs\agent.log -Encoding UTF8 | Select-String 'display|stream' | Select-Object -Last 6 | ForEach-Object { $_.Line.Substring(0, [Math]::Min(400, $_.Line.Length)) } }
        $log | ForEach-Object { Step "[$mode] log: $_" }
    }
}
catch { Step "FAILED: $($_.Exception.Message)" }
finally {
    Stop-VM -Name $name -TurnOff -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 3
    if (Get-VM -Name $name -ErrorAction SilentlyContinue) { Remove-GpuVM -Name $name -DeleteDisk -Confirm:$false | Out-Null }
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Step 'lock released'
}
