# Lab 042, part 5: what GpuVM costs while it waits in notices-only mode. Samples, every second for -Seconds, the
# working set and CPU of gpuvm.exe and every process under it (its WebView2 processes; the viewer is gone in that
# mode), and lists GpuVM's visible windows. Run it once with GpuVM open in Home (reference) and once after quitting with
# the machines left on (notices-only mode): pwsh -File labs/042-admin-dock/notices.ps1 -Label home|notices
param([Parameter(Mandatory)][string]$Label, [int]$Seconds = 30, [string]$OutDir = (Join-Path $PSScriptRoot 'out'))
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$app = Get-Process gpuvm -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $app) { throw 'GpuVM no está corriendo.' }

function Get-Tree([int]$Root) {
    $all = Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name
    $ids = [System.Collections.Generic.List[int]]::new(); $ids.Add($Root)
    for ($i = 0; $i -lt $ids.Count; $i++) { $all | Where-Object ParentProcessId -eq $ids[$i] | ForEach-Object { $ids.Add([int]$_.ProcessId) } }
    $ids
}

$samples = for ($s = 0; $s -lt $Seconds; $s++) {
    $procs = @(Get-Tree $app.Id | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    [pscustomobject]@{
        t = $s
        processes = $procs.Count
        names = ($procs | Group-Object ProcessName | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ','
        workingSetMB = [math]::Round(($procs | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 1)
        privateMB = [math]::Round(($procs | Measure-Object PrivateMemorySize64 -Sum).Sum / 1MB, 1)
        cpuSec = [math]::Round(($procs | Measure-Object -Property { $_.TotalProcessorTime.TotalSeconds } -Sum).Sum, 2)
    }
    Start-Sleep -Seconds 1
}
$first = $samples[0]; $last = $samples[-1]
$summary = [pscustomobject]@{
    label = $Label
    processes = $last.processes
    names = $last.names
    workingSetMB = [math]::Round(($samples | Measure-Object workingSetMB -Average).Average, 1)
    privateMB = [math]::Round(($samples | Measure-Object privateMB -Average).Average, 1)
    cpuPercentOfOneThread = [math]::Round(100 * ($last.cpuSec - $first.cpuSec) / ($Seconds - 1), 2)
}
$summary | ConvertTo-Json | Set-Content (Join-Path $OutDir "notices-$Label.json")
$summary | Format-List
