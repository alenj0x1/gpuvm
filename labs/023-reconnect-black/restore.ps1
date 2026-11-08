# Lab 023: puts sunshine.conf back after a run. Each key in -Restore gets its old value, or is removed when the
# value is $null (the file didn't have it). Called by run.ps1; also usable alone after an interrupted run:
#   pwsh -File labs/023-reconnect-black/restore.ps1 -Name win10 -StopTarget
param(
    [string]$Name = 'win10',
    [System.Collections.IDictionary]$Restore = @{ min_log_level = $null },
    [switch]$StopTarget
)
$ErrorActionPreference = 'Stop'
$tools = Join-Path $PSScriptRoot '..\..\tools\latency'
. (Join-Path $tools 'common.ps1')
$vm = Get-LatencyVM -Name $Name
& $vm.Module { param($a, $c) Wait-SunshineReady -Address $a -Credential $c -TimeoutSec 300 -Message 'Esperando a Sunshine' } $vm.Address $vm.Sunshine
# /api/config replaces the whole file: keys the file didn't have are left out again.
$changed = & $vm.Module {
    param($a, $c, $restore)
    $current = Invoke-SunshineApi -Address $a -Credential $c -Path '/api/config'
    $body = [ordered]@{}
    $differs = $false
    foreach ($p in $current.PSObject.Properties) {
        if ($p.Name -in 'platform', 'status', 'version') { continue }
        if ($restore.Contains($p.Name)) {
            if ($null -ne $restore[$p.Name]) { $body[$p.Name] = $restore[$p.Name] }
            if ("$($restore[$p.Name])" -ne "$($p.Value)") { $differs = $true }
        }
        else { $body[$p.Name] = $p.Value }
    }
    if (-not $differs) { return $false }
    Invoke-SunshineApi -Address $a -Credential $c -Method POST -Path '/api/config' -Body $body | Out-Null
    try { Invoke-SunshineApi -Address $a -Credential $c -Method POST -Path '/api/restart' -Body @{} | Out-Null } catch { }
    Start-Sleep -Seconds 5
    Wait-SunshineReady -Address $a -Credential $c -TimeoutSec 300 -Message 'Sunshine vuelve a su configuración'
    $true
} $vm.Address $vm.Sunshine $Restore
"sunshine.conf restored ($(@($Restore.Keys) -join ', ')): changed $changed" | Write-Host
if ($StopTarget) { & (Join-Path $tools 'stop-target.ps1') -Name $Name | Write-Host }
