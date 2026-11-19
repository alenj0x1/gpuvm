# Is the no-display state tied to the VM's GPU partition adapter (host side)? A good and a bad copy differ only in the
# GPU-P device's instance id in the guest (derived from the VM's virtual PCI bus), and the state survives a Windows
# restart. Copies agent-tpl the claim way until one is bad, then up to -Tries times: turn it off, remove and add the GPU
# partition adapter again with GpuVM's own settings, start it, and see whether the agent gets its display (and which
# instance id the guest now has). One lab lock; copies deleted.
param([string]$Template = 'agent-tpl', [int]$Copies = 14, [int]$Tries = 4, [string]$Me = 'agent-guest')
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
$m = Get-Module GpuVM
function Step($t) { "[$(Get-Date -Format HH:mm:ss)] $t" | Out-Host }
function Info([string]$n) { try { (Invoke-GpuVMAgent -Name $n -Method agent.info -TimeoutSec 5).result } catch { $null } }
function HasDisplay($x) { $x -and $null -ne $x.displays -and @($x.displays | Where-Object { $_.adapter }).Count -ge 1 }
function GpuId([string]$n, $cr) {
    try { Invoke-Command -VMName $n -Credential $cr { (Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object FriendlyName -match 'NVIDIA' | ForEach-Object { ($_.InstanceId -split '\\')[-1] }) -join ',' } } catch { "?" }
}
function WaitDisplay([string]$n, [int]$sec) {
    $w = [Diagnostics.Stopwatch]::StartNew(); $x = $null
    do { Start-Sleep -Seconds 2; $x = Info $n } until ((HasDisplay $x) -or $w.Elapsed.TotalSeconds -gt $sec)
    HasDisplay $x
}
& (Join-Path $repo 'labs\042-admin-dock\take-lock.ps1') -What "lab 051: no-display copy, GPU partition adapter re-added ($Template)" -Me $Me -MaxMinutes 240
if ($LASTEXITCODE -ne 0) { throw 'no lock' }
$done = $false; $badSeen = 0
try {
    for ($c = 1; $c -le $Copies -and -not $done; $c++) {
        $name = "a051g$c"
        try {
            New-GpuVM -Name $name -Template $Template | Out-Null
            Set-VMMemory -VMName $name -DynamicMemoryEnabled $false -StartupBytes 3GB
            Start-VM -Name $name
            $gc = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $name
            & $m { param($n, $cr) Wait-GuestReady -Name $n -Credential $cr } $name $gc
            Install-GpuVMAgent -Name $name | Out-Null
            $good = WaitDisplay $name 60
            Step "[$c] $(if ($good) { 'good' } else { 'BAD' }), GPU-P instance $(GpuId $name $gc)"
            if ($good) { continue }
            $badSeen++
            if ($badSeen -ge 2) { $done = $true }
            # control: a cold stop and start with the same adapter (Restart-VM was already tried: no display)
            Stop-VM -Name $name -Force
            Start-VM -Name $name
            Step "[$c] control, cold stop + start, same adapter: $(if (WaitDisplay $name 150) { 'display back' } else { 'still no display' }), GPU-P instance $(GpuId $name $gc)"
            for ($t = 1; $t -le $Tries; $t++) {
                Stop-VM -Name $name -Force
                $gpuParams = & $m { Get-GpuPartitionSettings -Percent 100 }
                Get-VMGpuPartitionAdapter -VMName $name | Remove-VMGpuPartitionAdapter
                Add-VMGpuPartitionAdapter -VMName $name @gpuParams
                Start-VM -Name $name
                $back = WaitDisplay $name 150
                Step "[$c] re-added the GPU partition adapter ($t): $(if ($back) { 'display back' } else { 'still no display' }), GPU-P instance $(GpuId $name $gc)"
                if ($back) {
                    # does it stay good across a plain restart?
                    Restart-VM -Name $name -Force
                    Start-Sleep -Seconds 20
                    Step "[$c] after a plain restart: $(if (WaitDisplay $name 150) { 'display' } else { 'NO display' }), GPU-P instance $(GpuId $name $gc)"
                    break
                }
            }
        }
        catch { Step "[$c] FAILED: $($_.Exception.Message)" }
        finally {
            Stop-VM -Name $name -TurnOff -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 3
            if (Get-VM -Name $name -ErrorAction SilentlyContinue) { Remove-GpuVM -Name $name -DeleteDisk -Confirm:$false | Out-Null }
        }
    }
    Step 'done'
}
finally {
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Step 'lock released'
}
