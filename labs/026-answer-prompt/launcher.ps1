# Lab 026, guest side, step 1: runs as SYSTEM in session 0 (a scheduled task) and starts helper.ps1 as SYSTEM in the
# console session on the secure desktop (winsta0\winlogon): a copy of its own token moved to that session
# (SetTokenInformation TokenSessionId needs SeTcbPrivilege, which SYSTEM has). Windows PowerShell 5.1.
param(
    [ValidateSet('read', 'yes', 'no')][string]$Action = 'read',
    [string]$Log = 'C:\GpuVM\lab026-launcher.txt'
)
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class GpuVMSecureDesktop {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [DllImport("kernel32.dll")] static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool DuplicateTokenEx(IntPtr t, uint access, IntPtr attrs, int level, int type, out IntPtr dup);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool SetTokenInformation(IntPtr t, int cls, ref uint info, int len);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessAsUser(IntPtr t, string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);

    // Runs `cmd` as SYSTEM on winsta0\winlogon of the console session; returns its exit code (or throws).
    public static uint Run(string cmd, uint timeoutMs) {
        IntPtr token, dup;
        if (!OpenProcessToken(GetCurrentProcess(), 0x000F01FF, out token)) throw new Exception("OpenProcessToken " + Marshal.GetLastWin32Error());
        if (!DuplicateTokenEx(token, 0x02000000, IntPtr.Zero, 2, 1, out dup)) throw new Exception("DuplicateTokenEx " + Marshal.GetLastWin32Error());
        uint session = WTSGetActiveConsoleSessionId();
        if (!SetTokenInformation(dup, 12, ref session, 4)) throw new Exception("SetTokenInformation " + Marshal.GetLastWin32Error());
        var si = new STARTUPINFO { cb = Marshal.SizeOf(typeof(STARTUPINFO)), lpDesktop = "winsta0\\winlogon", dwFlags = 1, wShowWindow = 0 };
        PROCESS_INFORMATION pi;
        if (!CreateProcessAsUser(dup, null, cmd, IntPtr.Zero, IntPtr.Zero, false, 0x08000000, IntPtr.Zero, null, ref si, out pi))
            throw new Exception("CreateProcessAsUser " + Marshal.GetLastWin32Error());
        WaitForSingleObject(pi.hProcess, timeoutMs);
        uint code; GetExitCodeProcess(pi.hProcess, out code);
        CloseHandle(pi.hProcess); CloseHandle(pi.hThread); CloseHandle(dup); CloseHandle(token);
        return code;
    }
}
'@
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\GpuVM\lab026-helper.ps1 -Action $Action"
    $code = [GpuVMSecureDesktop]::Run($cmd, 20000)
    Set-Content -LiteralPath $Log -Value "ok exit $code"
}
catch { Set-Content -LiteralPath $Log -Value "error $($_.Exception.Message)" }
