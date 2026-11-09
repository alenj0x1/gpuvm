# How the host feels while something heavy runs: every 200 ms, at normal priority (like the user's programs), it times
#   work   a fixed piece of CPU work calibrated to take ~2 ms on an idle PC
#   write  writing 4 KB to a file on the system drive and flushing it to disk (saving a document)
#   read   reading 64 KB from a random spot of a 256 MB file, bypassing the file cache (opening a file not in memory)
# and samples free memory. One JSON line per sample to -Out, until -StopFile appears (or -MaxSec passes).
# Run it in its own process: pwsh -File tools/host-probe/probe.ps1 -Out x.jsonl -StopFile x.stop
param(
    [Parameter(Mandatory)][string]$Out,
    [Parameter(Mandatory)][string]$StopFile,
    [int]$MaxSec = 7200,
    [string]$WorkDir = (Join-Path $env:TEMP 'gpuvm-probe')
)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class HostProbe {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadFile(SafeFileHandle h, IntPtr buffer, uint count, out uint read, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetFilePointerEx(SafeFileHandle h, long distance, IntPtr newPointer, uint method);
    [DllImport("kernel32.dll")] static extern IntPtr VirtualAlloc(IntPtr address, UIntPtr size, uint type, uint protect);

    static long spins = 1;
    static volatile int sink;
    static void Spin(long n) { int x = 0; for (long i = 0; i < n; i++) x = unchecked(x * 31 + (int)i); sink = x; }

    // Finds how many iterations take ~2 ms here when idle (median of several tries).
    public static void Calibrate() {
        long n = 100000;
        var sw = new Stopwatch();
        for (;;) { sw.Restart(); Spin(n); if (sw.Elapsed.TotalMilliseconds > 20) break; n *= 2; }
        var tries = new double[9];
        for (int i = 0; i < tries.Length; i++) { sw.Restart(); Spin(n); tries[i] = sw.Elapsed.TotalMilliseconds; }
        Array.Sort(tries);
        spins = (long)(n * 2.0 / tries[tries.Length / 2]);
    }

    public static double Work() { var sw = Stopwatch.StartNew(); Spin(spins); return sw.Elapsed.TotalMilliseconds; }

    public static double Write(string path) {
        var data = new byte[4096];
        var sw = Stopwatch.StartNew();
        using (var f = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough)) {
            f.Write(data, 0, data.Length); f.Flush(true);
        }
        return sw.Elapsed.TotalMilliseconds;
    }

    static IntPtr buffer = IntPtr.Zero;
    static readonly Random random = new Random();
    // FILE_FLAG_NO_BUFFERING: the read goes to the disk, with a buffer aligned to the page.
    public static double Read(string path, long size) {
        if (buffer == IntPtr.Zero) buffer = VirtualAlloc(IntPtr.Zero, (UIntPtr)65536, 0x3000, 0x04);
        long offset = (long)(random.NextDouble() * (size / 65536 - 1)) * 65536;
        var sw = Stopwatch.StartNew();
        using (var h = CreateFile(path, 0x80000000, 1, IntPtr.Zero, 3, 0x20000000, IntPtr.Zero)) {
            if (h.IsInvalid) throw new System.ComponentModel.Win32Exception();
            SetFilePointerEx(h, offset, IntPtr.Zero, 0);
            uint read;
            if (!ReadFile(h, buffer, 65536, out read, IntPtr.Zero)) throw new System.ComponentModel.Win32Exception();
        }
        return sw.Elapsed.TotalMilliseconds;
    }
}
'@
New-Item -ItemType Directory -Force $WorkDir, (Split-Path $Out) | Out-Null
$readFile = Join-Path $WorkDir 'read.bin'
$size = 256MB
if (-not (Test-Path $readFile) -or (Get-Item $readFile).Length -ne $size) {
    $bytes = [byte[]]::new(1MB); [Random]::new(7).NextBytes($bytes)
    $f = [IO.File]::Create($readFile)
    try { for ($i = 0; $i -lt 256; $i++) { $f.Write($bytes, 0, $bytes.Length) } } finally { $f.Dispose() }
}
[HostProbe]::Calibrate()
$writeFile = Join-Path $WorkDir 'write.bin'
$writer = [IO.StreamWriter]::new($Out, $true)
$writer.AutoFlush = $true
$deadline = (Get-Date).AddSeconds($MaxSec)
try {
    $i = 0
    while (-not (Test-Path -LiteralPath $StopFile) -and (Get-Date) -lt $deadline) {
        $work = [HostProbe]::Work()
        $write = [HostProbe]::Write($writeFile)
        $read = [HostProbe]::Read($readFile, $size)
        # Free memory every 5 s (a CIM query is not free itself).
        if ($i++ % 25 -eq 0) { $freeMB = [math]::Round((Get-CimInstance Win32_OperatingSystem -Property FreePhysicalMemory).FreePhysicalMemory / 1KB) }
        $writer.WriteLine((@{ t = (Get-Date).ToString('o'); work = [math]::Round($work, 3); write = [math]::Round($write, 3); read = [math]::Round($read, 3); freeMB = $freeMB } | ConvertTo-Json -Compress))
        Start-Sleep -Milliseconds 200
    }
}
finally { $writer.Dispose() }
