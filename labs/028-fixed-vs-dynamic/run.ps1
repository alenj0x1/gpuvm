# Lab 028: does a fixed VHDX make the VM's disk faster than a dynamic one? The max-performance profile pays for a
# fixed disk by writing the whole disk at creation (96 GB of zeros, minutes of a saturated SSD).
# Each round attaches two new data disks to a running VM (SCSI, like its system disk), one fixed and one dynamic,
# formats them inside and runs the same test on each, from inside the VM, without Windows' file cache:
#   fill      writing a 4 GB file in 1 MB blocks to an empty disk (a dynamic disk grows here: installing a game)
#   rewrite   writing the same file again (the space is already allocated)
#   seqRead   reading it in 1 MB blocks
#   rand4k    4 KB random reads and writes, one at a time, for 15 s each (latency p50/p99, IOPS)
# Rounds alternate the order (fixed first, then dynamic first). The disks are removed after each round.
# Run elevated on a running VM GpuVM can reach (lab 027 calls it with -DiskLab):
#   pwsh -File labs/028-fixed-vs-dynamic/run.ps1 -VMName lab027-4 -Credential (Get-Credential)
param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][pscredential]$Credential,
    [int]$Rounds = 2,
    [int]$DiskGB = 8,
    [string]$Out = (Join-Path $PSScriptRoot "out\$(Get-Date -Format 'yyyyMMdd-HHmmss')")
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Out | Out-Null
function Say([string]$text) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $text" -ForegroundColor Cyan }

$vm = Get-VM -Name $VMName
if ($vm.State -ne 'Running') { throw "La VM $VMName no está encendida." }
$dir = Join-Path (Split-Path (Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1).Path -Parent) 'lab028'
$freeGB = [math]::Floor(([IO.DriveInfo]::new((Split-Path $dir -Qualifier))).AvailableFreeSpace / 1GB)
if ($freeGB -lt $DiskGB * 2 + 10) { throw "Hacen falta $($DiskGB * 2 + 10) GB libres para los dos discos; hay $freeGB." }
New-Item -ItemType Directory -Force $dir | Out-Null

# Runs inside the guest (Windows PowerShell 5.1): formats the disk with the label, then times the test.
$bench = {
    param($label, $fileGB)
    $ErrorActionPreference = 'Stop'
    $disk = $null
    for ($i = 0; $i -lt 30 -and -not $disk; $i++) {
        $disk = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' } | Select-Object -First 1
        if (-not $disk) { Start-Sleep -Seconds 1 }
    }
    if (-not $disk) { throw 'El disco nuevo no apareció en la VM.' }
    if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT
    $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false | Out-Null
    $path = "$($part.DriveLetter):\bench.bin"
    if (-not ('Lab028' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class Lab028 {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadFile(SafeFileHandle h, IntPtr b, uint n, out uint done, IntPtr o);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteFile(SafeFileHandle h, IntPtr b, uint n, out uint done, IntPtr o);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetFilePointerEx(SafeFileHandle h, long d, IntPtr np, uint m);
    [DllImport("kernel32.dll")] static extern IntPtr VirtualAlloc(IntPtr a, UIntPtr s, uint t, uint p);
    const uint NO_BUFFERING = 0x20000000, WRITE_THROUGH = 0x80000000;
    static IntPtr buffer = VirtualAlloc(IntPtr.Zero, (UIntPtr)(1 << 20), 0x3000, 0x04);
    static SafeFileHandle Open(string path, bool write, bool create) {
        var h = CreateFile(path, write ? 0xC0000000 : 0x80000000, 0, IntPtr.Zero, create ? 2u : 3u, NO_BUFFERING | WRITE_THROUGH, IntPtr.Zero);
        if (h.IsInvalid) throw new System.ComponentModel.Win32Exception();
        return h;
    }
    // MB/s writing or reading the whole file in 1 MB blocks.
    public static double Sequential(string path, long bytes, bool write, bool create) {
        var rnd = new Random(1); var block = new byte[1 << 20]; rnd.NextBytes(block); Marshal.Copy(block, 0, buffer, block.Length);
        var sw = Stopwatch.StartNew();
        using (var h = Open(path, write, create)) {
            for (long done = 0; done < bytes; done += 1 << 20) {
                uint n; bool ok = write ? WriteFile(h, buffer, 1 << 20, out n, IntPtr.Zero) : ReadFile(h, buffer, 1 << 20, out n, IntPtr.Zero);
                if (!ok) throw new System.ComponentModel.Win32Exception();
            }
        }
        return bytes / 1048576.0 / sw.Elapsed.TotalSeconds;
    }
    // Latencies (ms) of 4 KB random reads or writes, one at a time, for the given seconds.
    public static double[] Random4k(string path, long bytes, bool write, double seconds) {
        var rnd = new Random(2); var list = new System.Collections.Generic.List<double>();
        using (var h = Open(path, write, false)) {
            var total = Stopwatch.StartNew(); var sw = new Stopwatch();
            while (total.Elapsed.TotalSeconds < seconds) {
                long offset = (long)(rnd.NextDouble() * (bytes / 4096 - 1)) * 4096;
                sw.Restart();
                SetFilePointerEx(h, offset, IntPtr.Zero, 0);
                uint n; bool ok = write ? WriteFile(h, buffer, 4096, out n, IntPtr.Zero) : ReadFile(h, buffer, 4096, out n, IntPtr.Zero);
                if (!ok) throw new System.ComponentModel.Win32Exception();
                list.Add(sw.Elapsed.TotalMilliseconds);
            }
        }
        return list.ToArray();
    }
}
'@
    }
    function Pct($values, $p) { $s = @($values | Sort-Object); [math]::Round($s[[math]::Min($s.Count - 1, [math]::Floor($s.Count * $p))], 3) }
    $bytes = [long]$fileGB * 1GB
    $r = [ordered]@{}
    $r.fillMBs = [math]::Round([Lab028]::Sequential($path, $bytes, $true, $true), 1)
    $r.rewriteMBs = [math]::Round([Lab028]::Sequential($path, $bytes, $true, $false), 1)
    $r.seqReadMBs = [math]::Round([Lab028]::Sequential($path, $bytes, $false, $false), 1)
    foreach ($kind in 'read', 'write') {
        $lat = [Lab028]::Random4k($path, $bytes, $kind -eq 'write', 15)
        $r["rand4k${kind}P50"] = Pct $lat 0.5
        $r["rand4k${kind}P99"] = Pct $lat 0.99
        $r["rand4k${kind}Iops"] = [math]::Round($lat.Count / 15)
    }
    Remove-Item $path
    # Offline before it is detached, as GpuVM does with shared disks.
    Set-Disk -Number $disk.Number -IsOffline $true
    $r
}

$results = [System.Collections.Generic.List[object]]::new()
try {
    for ($round = 1; $round -le $Rounds; $round++) {
        $order = if ($round % 2) { 'Fixed', 'Dynamic' } else { 'Dynamic', 'Fixed' }
        foreach ($type in $order) {
            $path = Join-Path $dir "$type-$round.vhdx"
            Say "Ronda $round, disco $type"
            $t = Get-Date
            if ($type -eq 'Fixed') { New-VHD -Path $path -SizeBytes ([uint64]$DiskGB * 1GB) -Fixed | Out-Null } else { New-VHD -Path $path -SizeBytes ([uint64]$DiskGB * 1GB) -Dynamic | Out-Null }
            $createSec = [math]::Round(((Get-Date) - $t).TotalSeconds, 1)
            $drive = Add-VMHardDiskDrive -VMName $VMName -Path $path -ControllerType SCSI -Passthru
            try {
                $r = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock $bench -ArgumentList "lab028$type", ($DiskGB / 2)
                $row = [ordered]@{ round = $round; type = $type; createSec = $createSec }
                foreach ($k in $r.Keys) { $row[$k] = $r[$k] }
                $row.fileGBAfter = [math]::Round((Get-Item $path).Length / 1GB, 2)
                $results.Add($row)
                Say ("  fill {0} MB/s, rewrite {1}, read {2}, 4k read p50 {3} ms, 4k write p50 {4} ms" -f $row.fillMBs, $row.rewriteMBs, $row.seqReadMBs, $row.rand4kreadP50, $row.rand4kwriteP50)
            }
            finally {
                Remove-VMHardDiskDrive -VMName $VMName -ControllerType SCSI -ControllerNumber $drive.ControllerNumber -ControllerLocation $drive.ControllerLocation
                Remove-Item -LiteralPath $path -Force
            }
        }
    }
}
finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    $results | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Out 'lab028.json')
    $results | ForEach-Object { [pscustomobject]$_ } | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
}
