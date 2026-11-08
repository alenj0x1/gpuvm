# Windows administrator prompts while Sunshine captures with WGC (labs 025 and 026). WGC can't stream the secure desktop
# where Windows draws those prompts, so GpuVM shows them on the host and answers them on the person's order.
# Installed by GpuVM in C:\Program Files\GpuVM\AdminPrompt (only administrators can change it). Windows PowerShell 5.1.
#   -Mode watch    runs as SYSTEM from boot (task GpuVM-AdminPrompt): when a prompt opens, reads its program and
#                  publisher and publishes them to the host through Hyper-V's data exchange (KVP, key GpuVMAdminPrompt);
#                  when it closes, publishes that it closed.
#   -Mode answer   (host, through PowerShell Direct as administrator) presses Yes or No, only if the prompt open is still
#                  the one the person saw (-PromptId: its consent.exe process id).
#   -Mode secure   started by the two above as SYSTEM on the secure desktop of the console session: reads the prompt
#                  with UI Automation and presses the button it was told to.
param(
    [ValidateSet('watch', 'answer', 'secure')][string]$Mode = 'watch',
    [ValidateSet('read', 'yes', 'no')][string]$Action = 'read',
    [int]$PromptId = 0,
    [string]$Out = ''
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$kvpKey = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest'

function Start-OnSecureDesktop([string]$Arguments, [int]$TimeoutMs = 15000) {
    if (-not ('GpuVMSecureDesktop' -as [type])) {
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
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool DuplicateTokenEx(IntPtr t, uint access, IntPtr attrs, int level, int type, out IntPtr dup);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool SetTokenInformation(IntPtr t, int cls, ref uint info, int len);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessAsUser(IntPtr t, string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);

    // Runs `cmd` as SYSTEM (this process's own token, moved to the console session) on winsta0\winlogon and waits.
    public static void Run(string cmd, uint timeoutMs) {
        IntPtr token, dup;
        if (!OpenProcessToken(GetCurrentProcess(), 0x000F01FF, out token)) throw new Exception("OpenProcessToken " + Marshal.GetLastWin32Error());
        try {
            if (!DuplicateTokenEx(token, 0x02000000, IntPtr.Zero, 2, 1, out dup)) throw new Exception("DuplicateTokenEx " + Marshal.GetLastWin32Error());
            try {
                uint session = WTSGetActiveConsoleSessionId();
                if (!SetTokenInformation(dup, 12, ref session, 4)) throw new Exception("SetTokenInformation " + Marshal.GetLastWin32Error());
                var si = new STARTUPINFO { cb = Marshal.SizeOf(typeof(STARTUPINFO)), lpDesktop = "winsta0\\winlogon", dwFlags = 1, wShowWindow = 0 };
                PROCESS_INFORMATION pi;
                if (!CreateProcessAsUser(dup, null, cmd, IntPtr.Zero, IntPtr.Zero, false, 0x08000000, IntPtr.Zero, null, ref si, out pi))
                    throw new Exception("CreateProcessAsUser " + Marshal.GetLastWin32Error());
                WaitForSingleObject(pi.hProcess, timeoutMs);
                CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
            }
            finally { CloseHandle(dup); }
        }
        finally { CloseHandle(token); }
    }
}
'@
    }
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    [GpuVMSecureDesktop]::Run("`"$exe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$here\admin-prompt.ps1`" -Mode secure $Arguments", $TimeoutMs)
}

function Invoke-Secure([string]$Action) {
    $file = Join-Path $here "secure-$Action.json"
    Remove-Item $file -ErrorAction SilentlyContinue
    Start-OnSecureDesktop "-Action $Action -Out `"$file`""
    if (Test-Path $file) { Get-Content -Raw $file | ConvertFrom-Json } else { $null }
}

function Publish([hashtable]$Value) {
    if (-not (Test-Path $kvpKey)) { New-Item -Path $kvpKey | Out-Null }
    Set-ItemProperty -Path $kvpKey -Name GpuVMAdminPrompt -Value ($Value | ConvertTo-Json -Compress) -Type String
}

switch ($Mode) {
    'secure' {
        $result = [ordered]@{ app = $null; publisher = $null; pressed = $null; error = $null }
        try {
            Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
            $A = [System.Windows.Automation.AutomationElement]
            $T = [System.Windows.Automation.TreeScope]
            $button = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
            $text = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
            $prompt = $A::RootElement.FindAll($T::Children, [System.Windows.Automation.Condition]::TrueCondition) |
                Where-Object { $_.Current.ClassName -like 'Credential Dialog Xaml Host*' } | Select-Object -First 1
            if (-not $prompt) { throw 'No prompt on the secure desktop.' }
            # Texts in order: title, question, program, publisher line ("Editor comprobado: ..." / "Editor: Desconocido"), details.
            $texts = @($prompt.FindAll($T::Descendants, $text) | ForEach-Object { $_.Current.Name } | Where-Object { $_ })
            if ($texts.Count -ge 4) { $result.app = $texts[2]; $result.publisher = ($texts[3] -split ':\s*', 2)[-1] }
            if ($Action -ne 'read') {
                $want = if ($Action -eq 'yes') { 'OkButton' } else { 'CancelButton' }
                $target = $prompt.FindAll($T::Descendants, $button) | Where-Object { $_.Current.AutomationId -eq $want } | Select-Object -First 1
                if (-not $target) { throw "No $want." }
                $target.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                $result.pressed = $want
            }
        }
        catch { $result.error = $_.Exception.Message }
        if ($Out) { $result | ConvertTo-Json | Set-Content -LiteralPath $Out -Encoding UTF8 }
    }
    'answer' {
        # Only the prompt the person saw: another one opened in between is never answered by this order.
        $open = @(Get-Process consent -ErrorAction SilentlyContinue)
        if (-not ($open | Where-Object Id -eq $PromptId)) { return 'changed' }
        $r = Invoke-Secure $(if ($Action -eq 'yes') { 'yes' } else { 'no' })
        if ($r -and $r.pressed) { 'done' } else { "error: $(if ($r) { $r.error } else { 'no answer' })" }
    }
    'watch' {
        $shown = 0
        Publish @{ open = $false }
        while ($true) {
            $consent = Get-Process consent -ErrorAction SilentlyContinue | Select-Object -First 1
            $id = if ($consent) { $consent.Id } else { 0 }
            if ($id -ne $shown) {
                if ($id) {
                    $r = Invoke-Secure 'read'
                    Publish @{ open = $true; id = $id; app = if ($r) { $r.app } else { $null }; publisher = if ($r) { $r.publisher } else { $null } }
                }
                else { Publish @{ open = $false } }
                $shown = $id
            }
            Start-Sleep -Milliseconds 400
        }
    }
}
