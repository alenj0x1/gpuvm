# The no-display state survives sign-out and a Windows restart (ccd-test, 2 of 2), so it lives on the machine's disk.
# What differs between a good and a bad copy? Copies agent-tpl the claim way until it has one of each, and from each one
# dumps: the GraphicsDrivers registry tree, display/monitor/GPU devices (with problem codes), the System log's errors
# and warnings since boot, the DxgKrnl logs, and the adapters before the agent's install. One lab lock; copies deleted.
param([string]$Template = 'agent-tpl', [int]$Copies = 14, [string]$Me = 'agent-guest')
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$outDir = Join-Path $PSScriptRoot ('out\diff-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $outDir | Out-Null
Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
$m = Get-Module GpuVM
function Step($t) { "[$(Get-Date -Format HH:mm:ss)] $t" | Out-Host }
function Info([string]$n) { try { (Invoke-GpuVMAgent -Name $n -Method agent.info -TimeoutSec 5).result } catch { $null } }
function HasDisplay($x) { $x -and $null -ne $x.displays -and @($x.displays | Where-Object { $_.adapter }).Count -ge 1 }
$dump = {
    $o = [ordered]@{}
    $o.devices = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.Class -in 'Display', 'Monitor' -or $_.FriendlyName -match 'NVIDIA|Hyper-V Video|Virtual Display' } |
        ForEach-Object { "$($_.Class) | $($_.FriendlyName) | $($_.Status) | problem $($_.Problem) | $($_.InstanceId)" } | Sort-Object)
    $f = Join-Path $env:TEMP 'lab051-gd.reg'
    reg export 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' $f /y | Out-Null
    $o.graphicsDrivers = Get-Content $f -Encoding Unicode
    Remove-Item $f
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $o.boot = $boot.ToString('HH:mm:ss')
    $o.systemLog = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $boot.AddMinutes(-10); Level = 1, 2, 3 } -ErrorAction SilentlyContinue |
        Sort-Object TimeCreated | ForEach-Object { "$($_.TimeCreated.ToString('HH:mm:ss')) $($_.ProviderName)#$($_.Id): $(($_.Message -split "`n")[0])" })
    $o.dxgkrnl = @(Get-WinEvent -ListLog '*DxgKrnl*', '*Display*' -ErrorAction SilentlyContinue | Where-Object RecordCount | ForEach-Object {
        $ln = $_.LogName
        Get-WinEvent -LogName $ln -MaxEvents 30 -ErrorAction SilentlyContinue | Sort-Object TimeCreated | ForEach-Object { "$ln $($_.TimeCreated.ToString('HH:mm:ss')) #$($_.Id): $(($_.Message -split "`n")[0])" } })
    $o
}
& (Join-Path $repo 'labs\042-admin-dock\take-lock.ps1') -What "lab 051: good vs bad copy of $Template (no-display)" -Me $Me -MaxMinutes 240
if ($LASTEXITCODE -ne 0) { throw 'no lock' }
$have = @{ good = $false; bad = $false }
try {
    for ($c = 1; $c -le $Copies -and -not ($have.good -and $have.bad); $c++) {
        $name = "a051d$c"
        try {
            New-GpuVM -Name $name -Template $Template | Out-Null
            Set-VMMemory -VMName $name -DynamicMemoryEnabled $false -StartupBytes 3GB
            Start-VM -Name $name
            $gc = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $name
            & $m { param($n, $cr) Wait-GuestReady -Name $n -Credential $cr } $name $gc
            $pre = Invoke-Command -VMName $name -Credential $gc $dump
            $inst = Install-GpuVMAgent -Name $name
            $sw = [Diagnostics.Stopwatch]::StartNew(); $i = $null
            do { Start-Sleep -Seconds 2; $i = Info $name } until ((HasDisplay $i) -or $sw.Elapsed.TotalSeconds -gt 60)
            $kind = if (HasDisplay $i) { 'good' } else { 'bad' }
            Step "[$c] $kind (restarted $($inst.restarted))"
            if ($have[$kind]) { continue }
            $have[$kind] = $true
            $post = Invoke-Command -VMName $name -Credential $gc $dump
            [ordered]@{ kind = $kind; beforeInstall = $pre; afterInstall = $post } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $outDir "$kind-copy$c.json")
            Step "[$c] dumped as $kind"
        }
        catch { Step "[$c] FAILED: $($_.Exception.Message)" }
        finally {
            Stop-VM -Name $name -TurnOff -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 3
            if (Get-VM -Name $name -ErrorAction SilentlyContinue) { Remove-GpuVM -Name $name -DeleteDisk -Confirm:$false | Out-Null }
        }
    }
    Step "done: good $($have.good), bad $($have.bad)"
}
finally {
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Step "results: $outDir; lock released"
}
