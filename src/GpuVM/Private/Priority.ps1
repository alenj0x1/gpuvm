# Heavy host work (applying Windows, copying disks) runs at the lowest priority Windows has for CPU, disk and memory:
# it takes every idle core and the disk when nothing else wants them, and steps aside the moment the user does
# something. A program runs inside a job object at idle priority, and so does every process it starts (DISM does the
# real work in DismHost.exe), each with low I/O and memory priority. The job also ends them if GpuVM goes away.

if (-not ('GpuVMLowPriority' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class GpuVMLowPriority {
    [StructLayout(LayoutKind.Sequential)] struct BASIC_LIMIT {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit;
        public UIntPtr Affinity; public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS { public ulong R, W, O, RB, WB, OB; }
    [StructLayout(LayoutKind.Sequential)] struct EXTENDED_LIMIT {
        public BASIC_LIMIT Basic; public IO_COUNTERS Io;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [StructLayout(LayoutKind.Sequential)] struct COMPLETION_PORT { public IntPtr Key, Port; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct STARTUPINFO {
        public int cb; public string Reserved, Desktop, Title; public int X, Y, XSize, YSize, XCount, YCount, Fill, Flags;
        public short ShowWindow, Reserved2; public IntPtr Reserved3, StdInput, StdOutput, StdError;
    }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr Process, Thread; public int ProcessId, ThreadId; }

    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref EXTENDED_LIMIT info, int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref COMPLETION_PORT info, int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateIoCompletionPort(IntPtr file, IntPtr port, IntPtr key, uint threads);
    [DllImport("kernel32.dll")] static extern bool GetQueuedCompletionStatus(IntPtr port, out uint message, out IntPtr key, out IntPtr overlapped, uint ms);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcess(string app, StringBuilder commandLine, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr process, out int code);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern bool SetProcessInformation(IntPtr process, int infoClass, ref uint info, int size);
    [DllImport("ntdll.dll")] static extern int NtSetInformationProcess(IntPtr process, int infoClass, ref int info, int size);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int infoClass, out int info, int size, IntPtr returned);

    const uint IDLE_PRIORITY_CLASS = 0x40, CREATE_SUSPENDED = 0x4, CREATE_NO_WINDOW = 0x08000000;
    const uint LIMIT_PRIORITY_CLASS = 0x20, LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
    const uint MSG_NEW_PROCESS = 6, PROCESS_SET_INFORMATION = 0x200, PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    const int ProcessIoPriority = 33, ProcessMemoryPriority = 0;

    // I/O priority Low (1) and memory priority Low (2): its reads and writes wait behind everyone else's, and the
    // pages it leaves in memory are the first ones Windows reuses.
    static void Lower(IntPtr process) {
        int io = 1;
        NtSetInformationProcess(process, ProcessIoPriority, ref io, 4);
        uint memory = 2;
        SetProcessInformation(process, ProcessMemoryPriority, ref memory, 4);
    }

    // Runs commandLine to the end at idle priority (and everything it starts) and returns its exit code.
    // Nothing is shown: the program gets no window, and its output is discarded.
    public static int Run(string commandLine) {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        IntPtr port = IntPtr.Zero;
        var pi = new PROCESS_INFORMATION();
        try {
            var limit = new EXTENDED_LIMIT();
            limit.Basic.LimitFlags = LIMIT_PRIORITY_CLASS | LIMIT_KILL_ON_JOB_CLOSE;
            limit.Basic.PriorityClass = IDLE_PRIORITY_CLASS;
            if (!SetInformationJobObject(job, 9, ref limit, Marshal.SizeOf(limit))) throw new System.ComponentModel.Win32Exception();
            port = CreateIoCompletionPort(new IntPtr(-1), IntPtr.Zero, IntPtr.Zero, 1);
            if (port == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
            var link = new COMPLETION_PORT { Key = job, Port = port };
            if (!SetInformationJobObject(job, 7, ref link, Marshal.SizeOf(link))) throw new System.ComponentModel.Win32Exception();

            var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si);
            if (!CreateProcess(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false,
                    CREATE_SUSPENDED | CREATE_NO_WINDOW | IDLE_PRIORITY_CLASS, IntPtr.Zero, null, ref si, out pi))
                throw new System.ComponentModel.Win32Exception();
            // Assigned before it runs a single instruction, so nothing it starts can escape the job.
            if (!AssignProcessToJobObject(job, pi.Process)) {
                var error = new System.ComponentModel.Win32Exception();
                TerminateProcess(pi.Process, 1);
                throw error;
            }
            Lower(pi.Process);
            ResumeThread(pi.Thread);
            while (WaitForSingleObject(pi.Process, 0) != 0) {
                uint message; IntPtr key, data;
                if (!GetQueuedCompletionStatus(port, out message, out key, out data, 250)) continue;
                if (message != MSG_NEW_PROCESS) continue;
                IntPtr child = OpenProcess(PROCESS_SET_INFORMATION, false, data.ToInt32());
                if (child != IntPtr.Zero) { Lower(child); CloseHandle(child); }
            }
            int code;
            GetExitCodeProcess(pi.Process, out code);
            return code;
        }
        finally {
            if (pi.Thread != IntPtr.Zero) CloseHandle(pi.Thread);
            if (pi.Process != IntPtr.Zero) CloseHandle(pi.Process);
            if (port != IntPtr.Zero) CloseHandle(port);
            CloseHandle(job);
        }
    }

    // A process's I/O priority (0 very low, 1 low, 2 normal), or -1 when it can't be read. Used by the labs.
    public static int IoPriority(int pid) {
        IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return -1;
        try { int value; return NtQueryInformationProcess(h, ProcessIoPriority, out value, 4, IntPtr.Zero) == 0 ? value : -1; }
        finally { CloseHandle(h); }
    }
}
'@
}

if (-not ('GpuVMPacedCopy' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public static class GpuVMPacedCopy {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadFile(SafeFileHandle h, IntPtr buffer, uint count, out uint done, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteFile(SafeFileHandle h, IntPtr buffer, uint count, out uint done, IntPtr overlapped);
    [DllImport("kernel32.dll")] static extern IntPtr VirtualAlloc(IntPtr address, UIntPtr size, uint type, uint protect);
    [DllImport("kernel32.dll")] static extern bool VirtualFree(IntPtr address, UIntPtr size, uint type);

    const uint READ = 0x80000000, WRITE = 0x40000000, NO_BUFFERING = 0x20000000, WRITE_THROUGH = 0x80000000, SEQUENTIAL = 0x08000000;
    const int Chunk = 4 << 20;
    // MB/s: where it starts, the most and the least it goes, and how slow one 4 MB write may be before backing off.
    // Defaults: what the paced copy uses (lab 027); the labs pass others to compare.
    public static double StartRate = 200, MaxRate = 400, MinRate = 25, SlowWriteMs = 40, RateStep = 10;

    // { seconds, average MB/s, times it backed off }
    public static double[] Copy(string source, string destination) {
        long length = new FileInfo(source).Length;
        IntPtr buffer = VirtualAlloc(IntPtr.Zero, (UIntPtr)Chunk, 0x3000, 0x04);
        double rate = StartRate; int backoffs = 0;
        var total = Stopwatch.StartNew(); var step = new Stopwatch(); var write = new Stopwatch();
        try {
            using (var src = CreateFile(source, READ, 1, IntPtr.Zero, 3, NO_BUFFERING | SEQUENTIAL, IntPtr.Zero))
            using (var dst = CreateFile(destination, WRITE, 0, IntPtr.Zero, 1, NO_BUFFERING | WRITE_THROUGH, IntPtr.Zero)) {
                if (src.IsInvalid || dst.IsInvalid) throw new System.ComponentModel.Win32Exception();
                for (long done = 0; done < length; ) {
                    step.Restart();
                    uint want = (uint)Math.Min(Chunk, length - done);
                    // Without the file cache, reads and writes go in whole sectors; the file is cut to size at the end.
                    uint aligned = (want + 4095) & ~4095u;
                    uint read, written;
                    if (!ReadFile(src, buffer, aligned, out read, IntPtr.Zero)) throw new System.ComponentModel.Win32Exception();
                    if (read < want) throw new IOException("El disco base terminó antes de lo esperado.");
                    write.Restart();
                    if (!WriteFile(dst, buffer, aligned, out written, IntPtr.Zero)) throw new System.ComponentModel.Win32Exception();
                    double ms = write.Elapsed.TotalMilliseconds;
                    done += want;
                    if (ms > SlowWriteMs) { rate = Math.Max(MinRate, rate * 0.6); backoffs++; }
                    else rate = Math.Min(MaxRate, rate + RateStep);
                    double wait = want / 1048576.0 / rate * 1000 - step.Elapsed.TotalMilliseconds;
                    if (wait >= 1) Thread.Sleep((int)wait);
                }
            }
            if (length % 4096 != 0) using (var f = new FileStream(destination, FileMode.Open, FileAccess.Write)) f.SetLength(length);
            File.SetAttributes(destination, File.GetAttributes(destination) & ~FileAttributes.ReadOnly);
        }
        finally { VirtualFree(buffer, UIntPtr.Zero, 0x8000); }
        double seconds = total.Elapsed.TotalSeconds;
        return new[] { seconds, length / 1048576.0 / seconds, backoffs };
    }
}
'@
}

# Quotes one argument for a Windows command line.
function ConvertTo-CommandLineArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# Runs a program at low priority (see above) and returns its exit code. Its output is not shown.
function Invoke-LowPriority {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    $line = (@($FilePath) + $ArgumentList | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '
    [GpuVMLowPriority]::Run($line)
}

# Copies a large file (a disk) without flooding the SSD. A plain copy queues gigabytes of writes and every program
# that saves a file waits behind them (lab 027: half a second per save while the base was copied). This one writes
# 4 MB at a time straight to the disk (no file cache, so the user's programs stay in memory), one write in flight,
# and paces itself: it speeds up while each write is quick and backs off as soon as one is slow (the disk is busy).
# The copy is never read-only, even when the source is. Returns how long it took and how often it backed off.
function Copy-PacedFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    if (Test-Path -LiteralPath $Destination) { throw "Ya existe $Destination." }
    try { [GpuVMPacedCopy]::Copy($Source, $Destination) }
    catch {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "No se pudo copiar el disco: $($_.Exception.InnerException.Message ?? $_.Exception.Message)"
    }
}
