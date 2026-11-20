// Lab 055: starts a program as a separate standard user (gpuvm-stream) inside the console session of another user
// (`agent`), the way Sunshine's service starts Sunshine as SYSTEM in that session (tools/sunshinesvc.cpp), but with
// a user token so Windows.Graphics.Capture works. C# 5 (Windows PowerShell's Add-Type). Needs SYSTEM (SeTcbPrivilege).
//   Stage 0 (SYSTEM, session 0): RunAsSystemInSession starts stage 1 as SYSTEM in the console session.
//   Stage 1 (SYSTEM, console session): GrantDesktop gives the user WinSta0 and WinSta0\Default, RunAsUser starts the
//   program with a batch logon of the user moved into this session (optionally at high integrity, so programs of
//   `agent`, medium integrity, can't send its windows messages: UIPI).
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

public static class StreamLauncher
{
    const int TokenSessionId = 12, TokenIntegrityLevel = 25;
    const uint MAXIMUM_ALLOWED = 0x02000000, CREATE_UNICODE_ENVIRONMENT = 0x400, CREATE_NO_WINDOW = 0x08000000, CREATE_BREAKAWAY_FROM_JOB = 0x01000000;
    const int LOGON32_LOGON_BATCH = 4, LOGON32_PROVIDER_DEFAULT = 0;
    const uint DACL_SECURITY_INFORMATION = 4;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [StructLayout(LayoutKind.Sequential)]
    struct SID_AND_ATTRIBUTES { public IntPtr Sid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROFILEINFO { public int dwSize, dwFlags; public string lpUserName, lpProfilePath, lpDefaultPath, lpServerName, lpPolicyPath; public IntPtr hProfile; }
    [StructLayout(LayoutKind.Sequential)]
    struct LSA_UNICODE_STRING { public ushort Length, MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)]
    struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory, ObjectName; public uint Attributes; public IntPtr SecurityDescriptor, SecurityQualityOfService; }

    [DllImport("kernel32.dll")] static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool DuplicateTokenEx(IntPtr t, uint access, IntPtr attrs, int level, int type, out IntPtr dup);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool SetTokenInformation(IntPtr t, int cls, ref uint value, int len);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool SetTokenInformation(IntPtr t, int cls, ref SID_AND_ATTRIBUTES value, int len);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LogonUser(string user, string domain, string password, int type, int provider, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessAsUser(IntPtr token, string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("userenv.dll", SetLastError = true)] static extern bool CreateEnvironmentBlock(out IntPtr env, IntPtr token, bool inherit);
    [DllImport("userenv.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LoadUserProfile(IntPtr token, ref PROFILEINFO info);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool ConvertStringSidToSid(string sid, out IntPtr psid);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr OpenWindowStation(string name, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr OpenDesktop(string name, uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true)] static extern bool CloseWindowStation(IntPtr h);
    [DllImport("user32.dll", SetLastError = true)] static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll", SetLastError = true)] static extern bool GetUserObjectSecurity(IntPtr h, ref uint si, byte[] sd, uint len, out uint needed);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetUserObjectSecurity(IntPtr h, ref uint si, IntPtr sd);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool ConvertSecurityDescriptorToStringSecurityDescriptor(byte[] sd, uint rev, uint si, out IntPtr sddl, out uint len);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string sddl, uint rev, out IntPtr sd, out uint len);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
    [DllImport("advapi32.dll")] static extern int GetLengthSid(IntPtr sid);
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system, ref LSA_OBJECT_ATTRIBUTES attrs, uint access, out IntPtr policy);
    [DllImport("advapi32.dll")] static extern uint LsaAddAccountRights(IntPtr policy, byte[] sid, LSA_UNICODE_STRING[] rights, uint count);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr policy);
    [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);

    static void Check(bool ok, string what) { if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error(), what); }

    static IntPtr last;
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    // Waits for the last started process; its exit code in hex, or "running".
    public static string WaitLast(uint ms) {
        if (WaitForSingleObject(last, ms) != 0) return "running";
        uint code; GetExitCodeProcess(last, out code); return "0x" + code.ToString("X8");
    }

    [DllImport("wtsapi32.dll", SetLastError = true)] static extern bool WTSQueryUserToken(uint session, out IntPtr token);
    // Control: the signed-in user's own token (lab only: that user would own Sunshine).
    public static int RunAsSessionUser(string commandLine, string dir)
    {
        IntPtr t, primary;
        Check(WTSQueryUserToken(WTSGetActiveConsoleSessionId(), out t), "WTSQueryUserToken");
        Check(DuplicateTokenEx(t, MAXIMUM_ALLOWED, IntPtr.Zero, 2, 1, out primary), "DuplicateTokenEx");
        CloseHandle(t);
        IntPtr env; Check(CreateEnvironmentBlock(out env, primary, false), "CreateEnvironmentBlock");
        try { return Start(primary, commandLine, dir, env); } finally { CloseHandle(primary); }
    }

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LogonUserExExW(string user, string domain, string password, int type, int provider, IntPtr groups, out IntPtr token, IntPtr logonSid, IntPtr profile, IntPtr profileLen, IntPtr quota);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetTokenInformation(IntPtr t, int cls, IntPtr buf, int len, out int needed);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetSecurityDescriptorDacl(IntPtr sd, out bool present, out IntPtr dacl, out bool defaulted);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool SetTokenInformation(IntPtr t, int cls, ref IntPtr value, int len);

    // The console session's logon SID (TOKEN_GROUPS from its user's token, TokenLogonSid = 28).
    static IntPtr SessionLogonSidGroups()
    {
        IntPtr t; Check(WTSQueryUserToken(WTSGetActiveConsoleSessionId(), out t), "WTSQueryUserToken");
        try {
            int n; GetTokenInformation(t, 28, IntPtr.Zero, 0, out n);
            IntPtr buf = Marshal.AllocHGlobal(n);
            Check(GetTokenInformation(t, 28, buf, n, out n), "GetTokenInformation(TokenLogonSid)");
            return buf;
        } finally { CloseHandle(t); }
    }

    public static uint ConsoleSession() { return WTSGetActiveConsoleSessionId(); }

    // Gives a SID a user right (SeBatchLogonRight: LogonUser batch; standard users don't have it by default).
    public static void AddRight(string sid, string right)
    {
        var attrs = new LSA_OBJECT_ATTRIBUTES(); IntPtr policy;
        uint st = LsaOpenPolicy(IntPtr.Zero, ref attrs, 0x00000800 | 0x00000010, out policy); // CREATE_ACCOUNT | LOOKUP_NAMES
        if (st != 0) throw new Win32Exception(LsaNtStatusToWinError(st), "LsaOpenPolicy");
        try
        {
            var s = new SecurityIdentifier(sid); var bytes = new byte[s.BinaryLength]; s.GetBinaryForm(bytes, 0);
            var u = new LSA_UNICODE_STRING(); u.Buffer = Marshal.StringToHGlobalUni(right);
            u.Length = (ushort)(right.Length * 2); u.MaximumLength = (ushort)(u.Length + 2);
            st = LsaAddAccountRights(policy, bytes, new[] { u }, 1);
            Marshal.FreeHGlobal(u.Buffer);
            if (st != 0) throw new Win32Exception(LsaNtStatusToWinError(st), "LsaAddAccountRights");
        }
        finally { LsaClose(policy); }
    }

    // Stage 0 -> stage 1: this process's SYSTEM token, moved to the console session.
    public static int RunAsSystemInSession(uint session, string commandLine)
    {
        IntPtr own, dup;
        Check(OpenProcessToken(GetCurrentProcess(), MAXIMUM_ALLOWED, out own), "OpenProcessToken");
        Check(DuplicateTokenEx(own, MAXIMUM_ALLOWED, IntPtr.Zero, 2, 1, out dup), "DuplicateTokenEx");
        CloseHandle(own);
        Check(SetTokenInformation(dup, TokenSessionId, ref session, 4), "SetTokenInformation(session)");
        try { return Start(dup, commandLine, null, IntPtr.Zero); } finally { CloseHandle(dup); }
    }

    // Adds an allow ACE for the SID to this session's WinSta0 and WinSta0\Default (run inside that session).
    public static string GrantDesktop(string sid)
    {
        var log = new StringBuilder();
        IntPtr ws = OpenWindowStation("WinSta0", false, 0x00040000 | 0x00020000); // WRITE_DAC | READ_CONTROL
        Check(ws != IntPtr.Zero, "OpenWindowStation");
        try { log.Append("winsta: ").Append(AddAce(ws, "(A;;0xF037F;;;" + sid + ")")); } finally { CloseWindowStation(ws); }
        IntPtr desk = OpenDesktop("Default", 0, false, 0x00040000 | 0x00020000);
        Check(desk != IntPtr.Zero, "OpenDesktop");
        try { log.Append(" desktop: ").Append(AddAce(desk, "(A;;0xF01FF;;;" + sid + ")")); } finally { CloseDesktop(desk); }
        return log.ToString();
    }

    static string AddAce(IntPtr h, string ace)
    {
        uint si = DACL_SECURITY_INFORMATION, needed;
        GetUserObjectSecurity(h, ref si, null, 0, out needed);
        var buf = new byte[needed];
        Check(GetUserObjectSecurity(h, ref si, buf, needed, out needed), "GetUserObjectSecurity");
        IntPtr p; uint len;
        Check(ConvertSecurityDescriptorToStringSecurityDescriptor(buf, 1, DACL_SECURITY_INFORMATION, out p, out len), "ToSddl");
        string sddl = Marshal.PtrToStringUni(p); LocalFree(p);
        if (sddl.Contains(ace)) return "already";
        IntPtr sd;
        Check(ConvertStringSecurityDescriptorToSecurityDescriptor(sddl + ace, 1, out sd, out len), "FromSddl");
        try { Check(SetUserObjectSecurity(h, ref si, sd), "SetUserObjectSecurity"); } finally { LocalFree(sd); }
        return "added";
    }

    // Stage 1: the user's batch logon, moved into this session, starting commandLine on WinSta0\Default.
    public static int RunAsUser(string user, string password, string commandLine, string dir, bool high, bool withSessionSid, string userSid, bool interactive)
    {
        IntPtr logon, primary;
        int logonType = interactive ? 2 : LOGON32_LOGON_BATCH; // LOGON32_LOGON_INTERACTIVE: Windows starts its per-user services
        IntPtr groups = withSessionSid ? SessionLogonSidGroups() : IntPtr.Zero;
        try {
            if (withSessionSid) Check(LogonUserExExW(user, ".", password, logonType, LOGON32_PROVIDER_DEFAULT, groups, out logon, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero), "LogonUserExExW");
            else Check(LogonUser(user, ".", password, logonType, LOGON32_PROVIDER_DEFAULT, out logon), "LogonUser");
        } finally { if (groups != IntPtr.Zero) Marshal.FreeHGlobal(groups); }
        Check(DuplicateTokenEx(logon, MAXIMUM_ALLOWED, IntPtr.Zero, 2, 1, out primary), "DuplicateTokenEx");
        CloseHandle(logon);
        try
        {
            uint session = WTSGetActiveConsoleSessionId();
            Check(SetTokenInformation(primary, TokenSessionId, ref session, 4), "SetTokenInformation(session)");
            if (high)
            {
                IntPtr label; Check(ConvertStringSidToSid("S-1-16-12288", out label), "ConvertStringSidToSid");
                var tml = new SID_AND_ATTRIBUTES { Sid = label, Attributes = 0x20 }; // SE_GROUP_INTEGRITY
                Check(SetTokenInformation(primary, TokenIntegrityLevel, ref tml, Marshal.SizeOf(typeof(SID_AND_ATTRIBUTES)) + GetLengthSid(label)), "SetTokenInformation(integrity)");
                LocalFree(label);
            }
            // Objects it creates (its processes, threads): only this user and SYSTEM, never the session's logon SID.
            IntPtr dsd; uint dlen;
            Check(ConvertStringSecurityDescriptorToSecurityDescriptor("D:(A;;GA;;;" + userSid + ")(A;;GA;;;SY)", 1, out dsd, out dlen), "DefaultDacl");
            bool present, defaulted; IntPtr dacl;
            Check(GetSecurityDescriptorDacl(dsd, out present, out dacl, out defaulted), "GetSecurityDescriptorDacl");
            Check(SetTokenInformation(primary, 6, ref dacl, IntPtr.Size), "SetTokenInformation(default DACL)");
            LocalFree(dsd);
            var profile = new PROFILEINFO { dwSize = Marshal.SizeOf(typeof(PROFILEINFO)), dwFlags = 1, lpUserName = user };
            Check(LoadUserProfile(primary, ref profile), "LoadUserProfile");
            IntPtr env;
            Check(CreateEnvironmentBlock(out env, primary, false), "CreateEnvironmentBlock");
            return Start(primary, commandLine, dir, env);
        }
        finally { CloseHandle(primary); }
    }

    static int Start(IntPtr token, string commandLine, string dir, IntPtr env)
    {
        var si = new STARTUPINFO { cb = Marshal.SizeOf(typeof(STARTUPINFO)), lpDesktop = "winsta0\\default" };
        PROCESS_INFORMATION pi;
        uint flags = CREATE_NO_WINDOW | (env != IntPtr.Zero ? CREATE_UNICODE_ENVIRONMENT : 0);
        // Out of the scheduled task's job: the Task Scheduler ends the whole job when the task ends.
        if (!CreateProcessAsUser(token, null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false, flags | CREATE_BREAKAWAY_FROM_JOB, env, dir, ref si, out pi))
            Check(CreateProcessAsUser(token, null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false, flags, env, dir, ref si, out pi), "CreateProcessAsUser");
        CloseHandle(pi.hThread); last = pi.hProcess;
        return pi.dwProcessId;
    }
}
