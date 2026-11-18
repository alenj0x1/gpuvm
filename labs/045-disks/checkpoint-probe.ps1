# Lab 045, part 1: can Hyper-V take and apply Standard checkpoints of a GPU-P VM while it is Off?
# Builds a throwaway VM (never booted) on a differencing disk over a base, adds a GPU partition adapter,
# and tries Checkpoint-VM / Restore-VMSnapshot / Remove-VMSnapshot. Verifies the disk content offline
# (a marker file written into the mounted disk). Removes everything at the end. Elevated PowerShell 7.
param(
    # A never-booted Windows base if there is one, else lab045-tpl's disk (any Windows disk works as a parent).
    [string]$Parent = $(@(Get-ChildItem 'C:\GpuVM\.bases\*\base.vhdx', 'C:\GpuVM\.templates\lab045-tpl\lab045-tpl.vhdx' -ErrorAction SilentlyContinue)[0].FullName),
    [string]$Work = 'C:\GpuVM\lab045-ck'
)
$ErrorActionPreference = 'Stop'
$name = 'lab045-ck'
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null
$result = [ordered]@{ startedAt = (Get-Date).ToString('o'); steps = [ordered]@{} }

function Step($label, [scriptblock]$body) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $r = & $body; $result.steps[$label] = [ordered]@{ ok = $true; ms = $sw.ElapsedMilliseconds; detail = "$r" } }
    catch { $result.steps[$label] = [ordered]@{ ok = $false; ms = $sw.ElapsedMilliseconds; error = $_.Exception.Message }; Write-Warning "$label : $($_.Exception.Message)" }
    Write-Host ("{0,-28} {1} {2} ms" -f $label, $result.steps[$label].ok, $sw.ElapsedMilliseconds)
}

function Set-Marker($text) {
    $disk = (Get-VMHardDiskDrive -VMName $name).Path
    $m = Mount-VHD -Path $disk -NoDriveLetter -PassThru | Get-Disk
    try {
        $part = Get-Partition -DiskNumber $m.Number | Sort-Object Size -Descending | Select-Object -First 1
        $tmp = Join-Path $env:TEMP 'lab045-mnt'
        New-Item -ItemType Directory -Force $tmp | Out-Null
        Add-PartitionAccessPath -DiskNumber $m.Number -PartitionNumber $part.PartitionNumber -AccessPath $tmp
        try {
            if ($null -ne $text) { Set-Content -LiteralPath (Join-Path $tmp 'lab045-marker.txt') -Value $text }
            $f = Join-Path $tmp 'lab045-marker.txt'
            if (Test-Path $f) { (Get-Content $f -Raw).Trim() } else { '<none>' }
        }
        finally { Remove-PartitionAccessPath -DiskNumber $m.Number -PartitionNumber $part.PartitionNumber -AccessPath $tmp; Remove-Item $tmp -Force }
    }
    finally { Dismount-VHD -Path $disk }
}

try {
    if (Get-VM -Name $name -ErrorAction SilentlyContinue) { throw "$name already exists; remove it first." }
    New-Item -ItemType Directory -Force (Join-Path $Work 'Virtual Hard Disks') | Out-Null
    $vhd = Join-Path $Work "Virtual Hard Disks\$name.vhdx"
    Step 'create-disk' { New-VHD -Path $vhd -ParentPath $Parent -Differencing | Out-Null }
    Step 'create-vm' { New-VM -Name $name -Generation 2 -MemoryStartupBytes 2GB -VHDPath $vhd -Path (Split-Path $Work) | Out-Null }
    Step 'add-gpu-p' { Add-VMGpuPartitionAdapter -VMName $name; (Get-VMGpuPartitionAdapter -VMName $name).Count }
    Step 'marker-A' { Set-Marker 'A' }
    Step 'checkpoint-disabled' { Checkpoint-VM -Name $name -SnapshotName 'should-fail' }
    Step 'set-standard' { Set-VM -Name $name -CheckpointType Standard -AutomaticCheckpointsEnabled $false; (Get-VM $name).CheckpointType }
    Step 'checkpoint-1' { Checkpoint-VM -Name $name -SnapshotName 'punto-1'; (Get-VMSnapshot -VMName $name).Name -join ',' }
    Step 'disk-after-cp' { (Get-VMHardDiskDrive -VMName $name).Path }
    Step 'marker-B' { Set-Marker 'B' }
    Step 'restore-1' { Get-VMSnapshot -VMName $name -Name 'punto-1' | Restore-VMSnapshot -Confirm:$false; (Get-VMHardDiskDrive -VMName $name).Path }
    Step 'marker-after-restore' { Set-Marker $null }
    Step 'gpu-after-restore' { (Get-VMGpuPartitionAdapter -VMName $name).Count }
    Step 'checkpoint-type-after' { "$((Get-VM $name).CheckpointType)" }
    Step 'set-disabled-keeps' { Set-VM -Name $name -CheckpointType Disabled; (Get-VMSnapshot -VMName $name).Count }
    Step 'remove-1-merge' { Get-VMSnapshot -VMName $name | Remove-VMSnapshot; $deadline = (Get-Date).AddMinutes(3); while ((Get-VM $name).Status -match 'Merg' -and (Get-Date) -lt $deadline) { Start-Sleep 1 }; (Get-VMHardDiskDrive -VMName $name).Path }
    Step 'marker-after-merge' { Set-Marker $null }
}
finally {
    if (Get-VM -Name $name -ErrorAction SilentlyContinue) {
        Get-VMSnapshot -VMName $name -ErrorAction SilentlyContinue | Remove-VMSnapshot -ErrorAction SilentlyContinue
        Remove-VM -Name $name -Force
    }
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    $result.finishedAt = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out "checkpoint-probe-$(Get-Date -Format yyyyMMdd-HHmmss).json")
}
