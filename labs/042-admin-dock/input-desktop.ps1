# Lab 042 helper: which desktop the guest's console is showing (Default or Winlogon, the secure desktop), and with
# -Restore, switch it back to Default when it is stuck on Winlogon with no administrator prompt or lock screen open.
# Why: killing consent.exe while its prompt is up (an early run of answer.ps1 did) leaves the console on the secure
# desktop; Sunshine then logs "Failed to sync desktop to thread" and the picture never connects. Never kill
# consent.exe: answer the prompt instead.
# Runs a one-time SYSTEM task in the guest that starts a hidden PowerShell in the console session (the only place
# that can read or switch the input desktop) and removes everything after.
# Run elevated: pwsh -File labs/042-admin-dock/input-desktop.ps1 -Name win-gpu [-Restore]
param([string]$Name = 'win-gpu', [switch]$Restore)
$ErrorActionPreference = 'Stop'
$m = Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force -PassThru -DisableNameChecking
$guest = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $Name
$probe = @'
param([string]$Out, [switch]$Restore)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class InputDesk {
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr OpenDesktop(string name, uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SwitchDesktop(IntPtr h);
    [DllImport("user32.dll", SetLastError = true)] static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool GetUserObjectInformation(IntPtr h, int index, StringBuilder info, int len, out int needed);
    public static string Name() {
        IntPtr d = OpenInputDesktop(0, false, 0x0001);
        if (d == IntPtr.Zero) return "error " + Marshal.GetLastWin32Error();
        var sb = new StringBuilder(256); int n;
        GetUserObjectInformation(d, 2, sb, 512, out n);
        CloseDesktop(d);
        return sb.ToString();
    }
    public static string ToDefault() {
        IntPtr d = OpenDesktop("Default", 0, false, 0x0100);
        if (d == IntPtr.Zero) return "open error " + Marshal.GetLastWin32Error();
        bool ok = SwitchDesktop(d);
        int err = Marshal.GetLastWin32Error();
        CloseDesktop(d);
        return ok ? "switched" : "switch error " + err;
    }
}
"@
$lines = @("input desktop: $([InputDesk]::Name())")
$busy = @(Get-Process consent, LogonUI -ErrorAction SilentlyContinue)
if ($Restore) {
    if ($busy) { $lines += "not restored: $($busy.Name -join ', ') open" }
    elseif ([InputDesk]::Name() -ne 'Default') { $lines += [InputDesk]::ToDefault(); $lines += "input desktop now: $([InputDesk]::Name())" }
}
$lines | Set-Content $Out
'@
Invoke-Command -VMName $Name -Credential $guest -ArgumentList $probe, [bool]$Restore -ScriptBlock {
    param($probe, $restore)
    $dir = 'C:\Program Files\GpuVM-lab'
    New-Item -ItemType Directory -Force $dir | Out-Null
    $script = Join-Path $dir 'input-desktop.ps1'
    $out = Join-Path $dir 'input-desktop.txt'
    Set-Content $script $probe -Encoding UTF8
    Remove-Item $out -ErrorAction SilentlyContinue
    # The watcher's own helper type starts a process as SYSTEM in the console session (on winsta0\winlogon; reading
    # and switching the input desktop works from there).
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $cmd = "`"$exe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Out `"$out`"$(if ($restore) { ' -Restore' })"
    # Through a one-time SYSTEM task: this session is an administrator, not SYSTEM, and can't set a token's session.
    $runner = Join-Path $dir 'runner.ps1'
    Set-Content $runner (@"
`$src = Get-Content -Raw 'C:\Program Files\GpuVM\AdminPrompt\admin-prompt.ps1'
`$start = `$src.IndexOf('function Add-SecureDesktopType'); `$end = `$src.IndexOf('function Start-OnSecureDesktop')
Invoke-Expression `$src.Substring(`$start, `$end - `$start)
Add-SecureDesktopType
[GpuVMSecureDesktop]::Run('$($cmd -replace "'", "''")', 10000) | Out-Null
"@) -Encoding UTF8
    $a = New-ScheduledTaskAction -Execute $exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runner`""
    Register-ScheduledTask -TaskName GpuVM-Lab042Desk -Action $a -User SYSTEM -RunLevel Highest -Force | Out-Null
    Start-ScheduledTask GpuVM-Lab042Desk
    for ($i = 0; $i -lt 60 -and -not (Test-Path $out); $i++) { Start-Sleep -Milliseconds 250 }
    Unregister-ScheduledTask GpuVM-Lab042Desk -Confirm:$false
    Get-Content $out -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
}
