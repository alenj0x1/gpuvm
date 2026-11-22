param(
    [ValidateSet('watch', 'answer', 'secure')][string]$Mode = 'watch',
    [ValidateSet('read', 'yes', 'no', 'serve')][string]$Action = 'read',
    [int]$PromptId = 0,
    [string]$Out = ''
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$kvpKey = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest'
# Only SYSTEM, administrators and the KVP service can write this key: an unelevated guest program can't forge an answer.
$hostKey = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\External'

function Add-SecureDesktopType {
    if ('GpuVMSecureDesktop' -as [type]) { return }
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

    public static int Run(string cmd, uint timeoutMs) {
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
                if (timeoutMs > 0) WaitForSingleObject(pi.hProcess, timeoutMs);
                CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
                return pi.dwProcessId;
            }
            finally { CloseHandle(dup); }
        }
        finally { CloseHandle(token); }
    }
}
'@
}

function Start-OnSecureDesktop([string]$Arguments, [int]$TimeoutMs = 15000) {
    Add-SecureDesktopType
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    [GpuVMSecureDesktop]::Run("`"$exe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$here\admin-prompt.ps1`" -Mode secure $Arguments", $TimeoutMs)
}

function Invoke-Secure([string]$Action) {
    $file = Join-Path $here "secure-$Action.json"
    Remove-Item $file -ErrorAction SilentlyContinue
    Start-OnSecureDesktop "-Action $Action -Out `"$file`"" | Out-Null
    if (Test-Path $file) { Get-Content -Raw $file | ConvertFrom-Json } else { $null }
}

function Publish([string]$Name, [hashtable]$Value) {
    if (-not (Test-Path $kvpKey)) { New-Item -Path $kvpKey | Out-Null }
    Set-ItemProperty -Path $kvpKey -Name $Name -Value ($Value | ConvertTo-Json -Compress) -Type String
}

function Write-Json([string]$Path, $Value) {
    $tmp = "$Path.tmp"
    $Value | ConvertTo-Json -Compress | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json } catch { $null }
}

function Read-HostAnswer {
    $raw = (Get-ItemProperty -Path $hostKey -Name GpuVMAdminPromptAnswer -ErrorAction SilentlyContinue).GpuVMAdminPromptAnswer
    if (-not $raw -or $raw.Length -gt 512) { return $null }
    $data = try { $raw | ConvertFrom-Json } catch { $null }
    if (-not $data) { return $null }
    $id = 0
    [void][int]::TryParse([string]$data.id, [ref]$id)
    [pscustomobject]@{ raw = $raw; id = $id; nonce = [string]$data.nonce; answer = [string]$data.answer }
}

function New-Nonce {
    $bytes = New-Object byte[] 16
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

switch ($Mode) {
    'secure' {
        $result = [ordered]@{ app = $null; publisher = $null; pressed = $null; error = $null }
        $prompt = $null
        try {
            Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
            $A = [System.Windows.Automation.AutomationElement]
            $T = [System.Windows.Automation.TreeScope]
            $button = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
            $text = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
            # consent.exe starts a moment before its window appears.
            $deadline = [DateTime]::UtcNow.AddSeconds($(if ($Action -eq 'serve') { 5 } else { 0 }))
            do {
                $prompt = $A::RootElement.FindAll($T::Children, [System.Windows.Automation.Condition]::TrueCondition) |
                    Where-Object { $_.Current.ClassName -like 'Credential Dialog Xaml Host*' } | Select-Object -First 1
                if (-not $prompt) { Start-Sleep -Milliseconds 50 }
            } while (-not $prompt -and [DateTime]::UtcNow -lt $deadline)
            if (-not $prompt) { throw 'No prompt on the secure desktop.' }
            # Texts in order: title, question, program, publisher line, details.
            $texts = @($prompt.FindAll($T::Descendants, $text) | ForEach-Object { $_.Current.Name } | Where-Object { $_ })
            if ($texts.Count -ge 4) { $result.app = $texts[2]; $result.publisher = ($texts[3] -split ':\s*', 2)[-1] }
            $press = $Action
            if ($Action -eq 'serve') {
                # Only administrators can write in this folder.
                if ($Out) { Write-Json $Out $result }
                $order = Join-Path $here "order-$PromptId.json"
                $press = $null
                $until = [DateTime]::UtcNow.AddMinutes(30)
                $n = 0
                while (-not $press -and [DateTime]::UtcNow -lt $until) {
                    $o = Read-Json $order
                    if ($o) {
                        Remove-Item -LiteralPath $order -ErrorAction SilentlyContinue
                        if ([int]$o.id -eq $PromptId -and $o.action -in 'yes', 'no') { $press = $o.action }
                        continue
                    }
                    if ((++$n % 16) -eq 0 -and -not (Get-Process -Id $PromptId -ErrorAction SilentlyContinue)) { break }
                    Start-Sleep -Milliseconds 30
                }
                if (-not $press) { return }
                $Out = Join-Path $here "result-$PromptId.json"
            }
            if ($press -ne 'read') {
                $want = if ($press -eq 'yes') { 'OkButton' } else { 'CancelButton' }
                $target = $prompt.FindAll($T::Descendants, $button) | Where-Object { $_.Current.AutomationId -eq $want } | Select-Object -First 1
                if (-not $target) { throw "No $want." }
                $target.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                $result.pressed = $want
            }
        }
        catch { $result.error = $_.Exception.Message }
        if ($Action -eq 'serve' -and -not $result.pressed -and -not $result.error) { return }
        if ($Out) { Write-Json $Out $result }
    }
    'answer' {
        $open = @(Get-Process consent -ErrorAction SilentlyContinue)
        if (-not ($open | Where-Object Id -eq $PromptId)) { return 'changed' }
        $r = Invoke-Secure $(if ($Action -eq 'yes') { 'yes' } else { 'no' })
        if ($r -and $r.pressed) { 'done' } else { "error: $(if ($r) { $r.error } else { 'no answer' })" }
    }
    'watch' {
        $shown = 0
        $nonce = $null
        $info = $null
        $handled = (Read-HostAnswer).raw
        Get-ChildItem -LiteralPath $here -Filter '*-*.json' -ErrorAction SilentlyContinue | Where-Object Name -match '^(order|result|read)-\d+\.json' | Remove-Item -ErrorAction SilentlyContinue
        Publish GpuVMAdminPrompt @{ open = $false }
        while ($true) {
            $consent = Get-Process consent -ErrorAction SilentlyContinue | Select-Object -First 1
            $id = if ($consent) { $consent.Id } else { 0 }
            if ($id -ne $shown) {
                Remove-Item -LiteralPath (Join-Path $here "read-$shown.json"), (Join-Path $here "order-$shown.json"), (Join-Path $here "result-$shown.json") -ErrorAction SilentlyContinue
                $shown = $id
                $info = $null
                if ($id) {
                    $nonce = New-Nonce
                    Publish GpuVMAdminPrompt @{ open = $true; id = $id; nonce = $nonce; reading = $true }
                    try { Start-OnSecureDesktop "-Action serve -PromptId $id -Out `"$(Join-Path $here "read-$id.json")`"" 0 | Out-Null } catch { }
                }
                else { $nonce = $null; Publish GpuVMAdminPrompt @{ open = $false } }
            }
            if ($id -and -not $info) {
                $read = Read-Json (Join-Path $here "read-$id.json")
                if ($read) {
                    $info = $read
                    Publish GpuVMAdminPrompt @{ open = $true; id = $id; nonce = $nonce; reading = $false; app = $read.app; publisher = $read.publisher }
                }
            }
            $answer = Read-HostAnswer
            if ($answer -and $answer.raw -ne $handled) {
                $handled = $answer.raw
                $result = 'changed'
                if ($id -and $answer.id -eq $id -and $nonce -and $answer.nonce -eq $nonce -and $answer.answer -in 'yes', 'no') {
                    $resultFile = Join-Path $here "result-$id.json"
                    Remove-Item -LiteralPath $resultFile -ErrorAction SilentlyContinue
                    Write-Json (Join-Path $here "order-$id.json") @{ id = $id; action = $answer.answer }
                    $r = $null
                    for ($i = 0; $i -lt 150 -and -not $r; $i++) { Start-Sleep -Milliseconds 20; $r = Read-Json $resultFile }
                    if (-not $r) {
                        Remove-Item -LiteralPath (Join-Path $here "order-$id.json") -ErrorAction SilentlyContinue
                        $r = Invoke-Secure $answer.answer
                    }
                    $result = if ($r -and $r.pressed) { 'done' } else { "error: $(if ($r) { $r.error } else { 'no answer' })" }
                    $nonce = $null
                }
                Publish GpuVMAdminPromptAnswered @{ nonce = $answer.nonce; result = $result }
            }
            Start-Sleep -Milliseconds $(if ($id) { 50 } else { 250 })
        }
    }
}
