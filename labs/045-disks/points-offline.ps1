# Lab 045, part 2: GpuVM's own restore points (differencing disks) on a throwaway GPU-P VM that never boots.
# Each step writes or reads a marker file inside the guest's Windows partition (mounted offline) and checks that
# going back, deleting (merging) and renaming keep exactly the expected content. Times each operation and the
# merge of a layer with -LayerGB of real data. Removes everything at the end. Elevated PowerShell 7.
param(
    [string]$Parent = 'C:\GpuVM\.bases\a9f7251fed9ef730\base.vhdx',
    [int]$LayerGB = 4
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$name = 'lab045-pt'
$renamed = 'lab045-pt2'
$root = & (Get-Module GpuVM) { Get-GpuVMDefaultRoot }
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null
$result = [ordered]@{ startedAt = (Get-Date).ToString('o'); layerGB = $LayerGB; checks = [System.Collections.Generic.List[object]]::new() }
$failures = 0

function Check($label, $expected, $actual, $ms) {
    $ok = "$expected" -eq "$actual"
    if (-not $ok) { $script:failures++ }
    $result.checks.Add([ordered]@{ label = $label; ok = $ok; expected = "$expected"; actual = "$actual"; ms = $ms })
    Write-Host ("{0,-46} {1,-5} expected={2} actual={3} {4}" -f $label, $ok, $expected, $actual, $(if ($null -ne $ms) { "$ms ms" }))
}
function Timed([scriptblock]$body) { $sw = [Diagnostics.Stopwatch]::StartNew(); $r = & $body; @{ r = $r; ms = $sw.ElapsedMilliseconds } }
function Marker($vm, $text, [int]$fillGB = 0) {
    $disk = (Get-VMHardDiskDrive -VMName $vm).Path
    & (Get-Module GpuVM) {
        param($disk, $text, $fillGB)
        Invoke-WithMountedWindows -Path $disk -ScriptBlock {
            param($r)
            $f = Join-Path $r 'lab045-marker.txt'
            if ($null -ne $text) { [IO.File]::WriteAllText($f, $text) }
            if ($fillGB -gt 0) {
                $buf = [byte[]]::new(16MB); $rng = [Random]::new(45)
                $fs = [IO.File]::Create((Join-Path $r 'lab045-fill.bin'))
                try { for ($i = 0; $i -lt $fillGB * 64; $i++) { $rng.NextBytes($buf); $fs.Write($buf, 0, $buf.Length) } } finally { $fs.Dispose() }
            }
            if (Test-Path $f) { [IO.File]::ReadAllText($f) } else { '<none>' }
        }
    } $disk $text $fillGB
}
function Points($vm) { (Get-GpuVMRestorePoint -Name $vm).points }
function State($vm) { & (Get-Module GpuVM) { param($n) Get-GpuVMState -Name $n } $vm }

try {
    foreach ($n in $name, $renamed) { if (Get-VM -Name $n -ErrorAction SilentlyContinue) { throw "$n already exists." } }
    $vmDir = Join-Path $root $name
    $vhd = Join-Path $vmDir "Virtual Hard Disks\$name.vhdx"
    New-Item -ItemType Directory -Force (Split-Path $vhd) | Out-Null
    New-VHD -Path $vhd -ParentPath $Parent -Differencing | Out-Null
    New-VM -Name $name -Generation 2 -MemoryStartupBytes 2GB -VHDPath $vhd -Path $root | Out-Null
    Add-VMGpuPartitionAdapter -VMName $name
    $state = [ordered]@{ name = $name; backend = 'hyperv-gpup'; profile = 'balanced'; vmDir = $vmDir; vhdPath = $vhd
        statePath = Join-Path $vmDir 'gpuvm.json'; installedApps = @('vlc'); config = (& (Get-Module GpuVM) { Resolve-GpuVMProfile -Name balanced })
        gpu = [ordered]@{ name = 'lab'; driverVersion = '0' } }
    & (Get-Module GpuVM) { param($s) Save-GpuVMState $s } $state

    Check 'marker A' 'A' (Marker $name 'A')
    $t = Timed { New-GpuVMRestorePoint -Name $name -Label 'uno' -Confirm:$false }; $p1 = $t.r.id
    Check 'create P1 (VM off)' 1 @(Points $name).Count $t.ms
    Check 'disk path unchanged' $vhd (Get-VMHardDiskDrive -VMName $name).Path
    Check 'P1 is read-only' $true (Get-Item (Join-Path $vmDir "Virtual Hard Disks\points\$p1.vhdx")).IsReadOnly
    $t = Timed { Marker $name 'B' $LayerGB }; Check "marker B + $LayerGB GB layer" 'B' $t.r $t.ms
    # Change what GpuVM knows about the guest: it must come back with the point.
    $s = State $name; $s['installedApps'] = @('vlc', 'steam'); & (Get-Module GpuVM) { param($s) Save-GpuVMState $s } $s
    $t = Timed { New-GpuVMRestorePoint -Name $name -Label 'dos' -Confirm:$false }; $p2 = $t.r.id
    Check 'create P2' 2 @(Points $name).Count $t.ms
    Check 'marker C' 'C' (Marker $name 'C')

    $t = Timed { Restore-GpuVMRestorePoint -Name $name -Id $p1 -Confirm:$false }
    Check 'back to P1 -> A' 'A' (Marker $name $null) $t.ms
    Check 'apps back to P1' 'vlc' ((State $name)['installedApps'] -join ',')
    Check 'GPU-P adapter kept' 1 @(Get-VMGpuPartitionAdapter -VMName $name).Count
    Check 'VM on P1' $p1 ((Points $name | Where-Object current).id)

    $t = Timed { Restore-GpuVMRestorePoint -Name $name -Id $p2 -Confirm:$false }
    Check 'back to P2 -> B' 'B' (Marker $name $null) $t.ms
    Check 'apps back to P2' 'vlc,steam' ((State $name)['installedApps'] -join ',')

    Check 'marker D' 'D' (Marker $name 'D')
    # P1 has one child (P2, a point): P2 merges into P1, the VM's disk is pointed at the result.
    $t = Timed { Remove-GpuVMRestorePoint -Name $name -Id $p1 -Confirm:$false }
    Check 'delete P1 (merge point into point)' 1 @(Points $name).Count $t.ms
    Check 'after delete P1 -> D' 'D' (Marker $name $null)
    $t = Timed { Restore-GpuVMRestorePoint -Name $name -Id $p2 -Confirm:$false }
    Check 'back to P2 after merge -> B' 'B' (Marker $name $null) $t.ms

    # Going back while keeping the present as a point.
    Check 'marker E' 'E' (Marker $name 'E')
    Restore-GpuVMRestorePoint -Name $name -Id $p2 -SaveCurrent -Confirm:$false | Out-Null
    $saved = (Points $name | Where-Object { $_.id -ne $p2 }).id
    Check 'SaveCurrent kept a point' 2 @(Points $name).Count
    Check 'after SaveCurrent -> B' 'B' (Marker $name $null)
    Restore-GpuVMRestorePoint -Name $name -Id $saved -Confirm:$false | Out-Null
    Check 'back to saved -> E' 'E' (Marker $name $null)
    # P2 now has two children (the saved point and... no: saved sits on P2's old top). Check the branch rule.
    Restore-GpuVMRestorePoint -Name $name -Id $p2 -Confirm:$false | Out-Null
    $err = $null; try { Remove-GpuVMRestorePoint -Name $name -Id $p2 -Confirm:$false } catch { $err = $_.Exception.Message }
    Check 'delete a point two others sit on is refused' $true ([bool]$err)

    # Rename with points: the chain must follow the folder.
    $t = Timed { try { Rename-GpuVM -Name $name -NewName $renamed -Confirm:$false | Out-Null } catch { Write-Warning "after rename: $($_.Exception.Message)" } }
    Check 'rename with points' $true ([bool](Get-VM -Name $renamed -ErrorAction SilentlyContinue)) $t.ms
    $vm2 = Join-Path $root $renamed
    Check 'chain readable after rename -> B' 'B' (Marker $renamed $null)
    $chainOk = (Get-VHD (Get-VMHardDiskDrive -VMName $renamed).Path).ParentPath -like "$vm2*"
    Check 'parent path in new folder' $true $chainOk
    Restore-GpuVMRestorePoint -Name $renamed -Id $saved -Confirm:$false | Out-Null
    Check 'restore after rename -> E' 'E' (Marker $renamed $null)

    # Delete everything: the VM keeps what it has (E).
    $deleted = 0
    for ($i = 0; $i -lt 5 -and @(Points $renamed).Count; $i++) {
        foreach ($p in @(Points $renamed)) { try { $t = Timed { Remove-GpuVMRestorePoint -Name $renamed -Id $p.id -Confirm:$false }; $deleted++; $result["delete-$deleted-ms"] = $t.ms } catch { } }
    }
    Check 'all points deleted' 0 @(Points $renamed).Count
    Check 'after deleting all -> E' 'E' (Marker $renamed $null)
    Check 'disk is no longer differencing on a point' $Parent (Get-VHD (Get-VMHardDiskDrive -VMName $renamed).Path).ParentPath
    Check 'points folder empty' 0 @(Get-ChildItem (Join-Path $vm2 'Virtual Hard Disks\points') -File -ErrorAction SilentlyContinue).Count
}
finally {
    foreach ($n in $name, $renamed) {
        if (Get-VM -Name $n -ErrorAction SilentlyContinue) { Remove-VM -Name $n -Force }
        $d = Join-Path $root $n
        if (Test-Path $d) { Get-ChildItem $d -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }; Remove-Item $d -Recurse -Force }
    }
    $result.failures = $failures
    $result.finishedAt = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out "points-offline-$(Get-Date -Format yyyyMMdd-HHmmss).json")
    Write-Host "failures: $failures"
}
