# Run over PowerShell Direct as a script block or Invoke-Command -FilePath: guests keep the Restricted execution policy.
# When rebootNeeded, restart from inside the guest: Restart-VM -Force right after the install loses its registry changes.
[CmdletBinding()]
param(
    [string]$Staging = 'C:\ProgramData\GpuVM\Agent\staging',
    [byte[]]$Secret,
    [ValidateSet('agent', 'previous')][string]$SignInAs = 'agent',
    [switch]$Uninstall,
    [switch]$RemoveUser,
    [switch]$PrepareTemplate,
    [switch]$Full,
    [string]$ExpectedSha256,
    # Empty: keep what is recorded; '-': remove it.
    [ValidatePattern('^(|-|[0-9]{4}x[0-9]{3,4}@[0-9]{2,3})\z')][string]$StreamMode = ''
)
$ErrorActionPreference = 'Stop'

$AppDir = 'C:\Program Files\GpuVM Agent'
$DataDir = 'C:\ProgramData\GpuVM\Agent'
$Exe = Join-Path $AppDir 'gpuvm-agent.exe'
$ServiceName = 'GpuVMAgent'
$UserName = 'agent'
$BackupKey = 'HKLM:\SOFTWARE\GpuVM\Agent\Backup'
$Winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$PrevSecret = 'GpuVMAgent_PreviousDefaultPassword'
$SidSystem = New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'
$SidAdmins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
$SidUsers = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'
$notes = New-Object Collections.Generic.List[string]

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole($SidAdmins)) { throw 'Run as an administrator of the guest.' }

if (-not ('GpuVMAgentLsa' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GpuVMAgentLsa {
    [StructLayout(LayoutKind.Sequential)] struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system, ref LSA_OBJECT_ATTRIBUTES attrs, uint access, out IntPtr policy);
    [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr policy, ref LSA_UNICODE_STRING key, IntPtr data);
    [DllImport("advapi32.dll")] static extern uint LsaRetrievePrivateData(IntPtr policy, ref LSA_UNICODE_STRING key, out IntPtr data);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr h);
    [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr p);
    [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);
    const uint STATUS_OBJECT_NAME_NOT_FOUND = 0xC0000034;
    static IntPtr Open() {
        var a = new LSA_OBJECT_ATTRIBUTES(); a.Length = Marshal.SizeOf(a);
        IntPtr h; uint s = LsaOpenPolicy(IntPtr.Zero, ref a, 0x00000020 | 0x00000004, out h); // CREATE_SECRET | GET_PRIVATE_INFORMATION
        if (s != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(s));
        return h;
    }
    static LSA_UNICODE_STRING Str(string s, out IntPtr mem) {
        mem = Marshal.StringToHGlobalUni(s);
        var u = new LSA_UNICODE_STRING(); u.Length = (ushort)(s.Length * 2); u.MaximumLength = (ushort)(s.Length * 2 + 2); u.Buffer = mem; return u;
    }
    // value null deletes the secret
    public static void Store(string key, string value) {
        IntPtr h = Open(), km, vm = IntPtr.Zero, vp = IntPtr.Zero;
        var k = Str(key, out km);
        try {
            if (value != null) { var v = Str(value, out vm); vp = Marshal.AllocHGlobal(Marshal.SizeOf(v)); Marshal.StructureToPtr(v, vp, false); }
            uint s = LsaStorePrivateData(h, ref k, vp);
            if (s != 0 && !(value == null && s == STATUS_OBJECT_NAME_NOT_FOUND)) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(s));
        } finally {
            Marshal.FreeHGlobal(km);
            if (vm != IntPtr.Zero) { Marshal.Copy(new byte[value.Length * 2], 0, vm, value.Length * 2); Marshal.FreeHGlobal(vm); }
            if (vp != IntPtr.Zero) Marshal.FreeHGlobal(vp);
            LsaClose(h);
        }
    }
    public static string Read(string key) {
        IntPtr h = Open(), km, d; var k = Str(key, out km);
        try {
            uint s = LsaRetrievePrivateData(h, ref k, out d);
            if (s != 0) return null;
            try { var u = (LSA_UNICODE_STRING)Marshal.PtrToStructure(d, typeof(LSA_UNICODE_STRING)); return Marshal.PtrToStringUni(u.Buffer, u.Length / 2); }
            finally { LsaFreeMemory(d); }
        } finally { Marshal.FreeHGlobal(km); LsaClose(h); }
    }
    public static bool Exists(string key) {
        IntPtr h = Open(), km, d; var k = Str(key, out km);
        try { uint s = LsaRetrievePrivateData(h, ref k, out d); if (s == 0) { LsaFreeMemory(d); return true; } return false; }
        finally { Marshal.FreeHGlobal(km); LsaClose(h); }
    }
    // copies one secret to another without the value ever becoming a managed string; false when src is absent
    public static bool Copy(string src, string dst) {
        IntPtr h = Open(), sm, dm, d; var s = Str(src, out sm); var t = Str(dst, out dm);
        try {
            uint r = LsaRetrievePrivateData(h, ref s, out d);
            if (r == STATUS_OBJECT_NAME_NOT_FOUND) return false;
            if (r != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(r));
            try { r = LsaStorePrivateData(h, ref t, d); if (r != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(r)); }
            finally { LsaFreeMemory(d); }
            return true;
        } finally { Marshal.FreeHGlobal(sm); Marshal.FreeHGlobal(dm); LsaClose(h); }
    }
}
'@
}
if (-not ('GpuVMAgentProfile' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class GpuVMAgentProfile {
    [DllImport("userenv.dll", CharSet = CharSet.Unicode)] public static extern int CreateProfile(string sid, string user, StringBuilder path, uint size);
}
'@
}

function Set-Value([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }   # creates missing keys only; existing values stay
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Initialize-BackupKey {
    if (-not (Test-Path $BackupKey)) { New-Item -Path $BackupKey -Force | Out-Null }
    $acl = New-Object Security.AccessControl.RegistrySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in $SidSystem, $SidAdmins) {
        $acl.AddAccessRule((New-Object Security.AccessControl.RegistryAccessRule($sid, 'FullControl', 'ContainerInherit', 'None', 'Allow')))
    }
    Set-Acl -Path $BackupKey -AclObject $acl
}

function Backup-Value([string]$Path, [string]$Name) {
    $id = ($Path -replace '^HKLM:\\', '') + '|' + $Name
    Initialize-BackupKey
    if ($null -ne (Get-ItemProperty -Path $BackupKey -Name $id -ErrorAction SilentlyContinue)) { return }
    $cur = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    $saved = if ($null -eq $cur) { '<absent>' } else {
        $kind = (Get-Item $Path).GetValueKind($Name)
        "$kind|$($cur.$Name)"
    }
    New-ItemProperty -Path $BackupKey -Name $id -Value $saved -PropertyType String -Force | Out-Null
}

function Restore-Value([string]$Path, [string]$Name) {
    $id = ($Path -replace '^HKLM:\\', '') + '|' + $Name
    $b = Get-ItemProperty -Path $BackupKey -Name $id -ErrorAction SilentlyContinue
    if ($null -eq $b) { return }
    $saved = $b.$id
    if ($saved -eq '<absent>') {
        Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    } else {
        $kind, $val = $saved -split '\|', 2
        Set-Value $Path $Name $val $kind
    }
    Remove-ItemProperty -Path $BackupKey -Name $id
}

function Get-Reg([string]$Path, [string]$Name) {
    $p = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $p) { $null } else { $p.$Name }
}

function Set-ProtectedAcl([string]$Path, [bool]$UsersReadExecute) {
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [Security.AccessControl.PropagationFlags]::None
    foreach ($sid in $SidSystem, $SidAdmins) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', $inherit, $none, 'Allow')))
    }
    if ($UsersReadExecute) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($SidUsers, 'ReadAndExecute', $inherit, $none, 'Allow')))
    }
    $acl.SetOwner($SidAdmins)
    Set-Acl -Path $Path -AclObject $acl
    $todo = New-Object Collections.Generic.Queue[string]
    $todo.Enqueue($Path)
    while ($todo.Count) {
        foreach ($item in @(Get-ChildItem -LiteralPath $todo.Dequeue() -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                if ($item.PSIsContainer) { & cmd.exe /c rmdir "$($item.FullName)" } else { & cmd.exe /c del /f /q /a "$($item.FullName)" }
                continue
            }
            $a = Get-Acl -LiteralPath $item.FullName
            $a.SetAccessRuleProtection($false, $false)
            foreach ($r in @($a.Access | Where-Object { -not $_.IsInherited })) { [void]$a.RemoveAccessRule($r) }
            $a.SetOwner($SidAdmins)
            Set-Acl -LiteralPath $item.FullName -AclObject $a
            if ($item.PSIsContainer) { $todo.Enqueue($item.FullName) }
        }
    }
}

# Users may create folders under C:\ProgramData: a planted junction or foreign folder is removed without following it.
function Test-Trusted([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
    $owner = (Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier])
    $owner -eq $SidSystem -or $owner -eq $SidAdmins
}
function Initialize-DataDir {
    foreach ($p in (Split-Path $DataDir -Parent), $DataDir) {
        if ((Test-Path -LiteralPath $p) -and -not (Test-Trusted $p)) {
            $notes.Add("removed $p (a link or a folder owned by someone else)")
            & cmd.exe /c rmdir /s /q "$p"
        }
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
        if (-not (Test-Trusted $p)) { throw "$p isn't safe (a link or owned by someone else) even after recreating it" }
    }
    Set-ProtectedAcl $DataDir $false
}

function New-Password {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 28
    $rng.GetBytes($bytes)
    $sb = New-Object Text.StringBuilder 'Ag7#'
    foreach ($b in $bytes) { [void]$sb.Append($chars[$b % $chars.Length]) }
    $sb.ToString()
}

function Get-AgentProfile([string]$Sid) {
    $p = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid" -ErrorAction SilentlyContinue
    if ($p) { [Environment]::ExpandEnvironmentVariables($p.ProfileImagePath) } else { $null }
}

function Invoke-AgentHive([string]$Sid, [string]$ProfilePath, [scriptblock]$Script) {
    $loaded = Test-Path "Registry::HKEY_USERS\$Sid"
    $root = "Registry::HKEY_USERS\$Sid"
    if (-not $loaded) {
        $root = 'Registry::HKEY_USERS\GpuVMAgentSetup'
        $out = & reg.exe load 'HKU\GpuVMAgentSetup' (Join-Path $ProfilePath 'NTUSER.DAT') 2>&1
        if ($LASTEXITCODE -ne 0) { throw "can't load the agent's registry: $out" }
    }
    try { & $Script $root }
    finally {
        if (-not $loaded) {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            for ($i = 0; $i -lt 10; $i++) {
                & reg.exe unload 'HKU\GpuVMAgentSetup' 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { break }
                Start-Sleep -Milliseconds 300
            }
        }
    }
}

$WinlogonValues = 'AutoAdminLogon', 'DefaultUserName', 'DefaultDomainName', 'AutoLogonCount'
$PrevPlainSecret = 'GpuVMAgent_PreviousPlainDefaultPassword'

function Set-AgentAutologon([string]$Password) {
    foreach ($n in $WinlogonValues) { Backup-Value $Winlogon $n }
    $plainMarker = 'PLAIN|DefaultPassword'
    if ($null -eq (Get-ItemProperty -Path $BackupKey -Name $plainMarker -ErrorAction SilentlyContinue)) {
        $plain = Get-Reg $Winlogon 'DefaultPassword'
        if ($null -ne $plain) { [GpuVMAgentLsa]::Store($PrevPlainSecret, [string]$plain) }
        New-ItemProperty -Path $BackupKey -Name $plainMarker -Value $(if ($null -ne $plain) { 'lsa' } else { '<absent>' }) -PropertyType String -Force | Out-Null
        $plain = $null
    }
    $marker = 'LSA|DefaultPassword'
    if ($null -eq (Get-ItemProperty -Path $BackupKey -Name $marker -ErrorAction SilentlyContinue)) {
        $had = [GpuVMAgentLsa]::Copy('DefaultPassword', $PrevSecret)
        New-ItemProperty -Path $BackupKey -Name $marker -Value $(if ($had) { 'saved' } else { '<absent>' }) -PropertyType String -Force | Out-Null
    }
    [GpuVMAgentLsa]::Store('DefaultPassword', $Password)
    Set-Value $Winlogon 'AutoAdminLogon' '1' 'String'
    Set-Value $Winlogon 'DefaultUserName' $UserName 'String'
    Set-Value $Winlogon 'DefaultDomainName' $env:COMPUTERNAME 'String'
    Remove-ItemProperty -Path $Winlogon -Name 'AutoLogonCount' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $Winlogon -Name 'DefaultPassword' -ErrorAction SilentlyContinue   # never in plain text
}

function Restore-PreviousAutologon {
    $marker = 'LSA|DefaultPassword'
    $m = Get-ItemProperty -Path $BackupKey -Name $marker -ErrorAction SilentlyContinue
    if ($null -eq $m) { return $false }
    if ($m.$marker -eq 'saved') {
        [void][GpuVMAgentLsa]::Copy($PrevSecret, 'DefaultPassword')
        [GpuVMAgentLsa]::Store($PrevSecret, $null)
    } else {
        [GpuVMAgentLsa]::Store('DefaultPassword', $null)
    }
    Remove-ItemProperty -Path $BackupKey -Name $marker
    foreach ($n in $WinlogonValues) { Restore-Value $Winlogon $n }
    Restore-Value $Winlogon 'DefaultPassword'   # entries written by 0.1 installs
    $plainMarker = 'PLAIN|DefaultPassword'
    $pm = Get-ItemProperty -Path $BackupKey -Name $plainMarker -ErrorAction SilentlyContinue
    if ($null -ne $pm) {
        if ($pm.$plainMarker -eq 'lsa') {
            $v = [GpuVMAgentLsa]::Read($PrevPlainSecret)
            if ($null -ne $v) { Set-Value $Winlogon 'DefaultPassword' $v 'String' }
            [GpuVMAgentLsa]::Store($PrevPlainSecret, $null)
            $v = $null
        }
        Remove-ItemProperty -Path $BackupKey -Name $plainMarker
    }
    $true
}

$MachinePolicies = @(
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'; Name = 'DisablePrivacyExperience'; Value = 1 },
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'EnableFirstLogonAnimation'; Value = 0 }
)

$ModeKey = 'HKLM:\SOFTWARE\GpuVM\Agent'
function Set-AgentMode([string]$Sid, [string]$Mode) {
    if (-not (Test-Path $ModeKey)) { New-Item -Path $ModeKey -Force | Out-Null }
    New-ItemProperty -Path $ModeKey -Name 'AgentSid' -Value $Sid -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $ModeKey -Name 'SignInAs' -Value $Mode -PropertyType String -Force | Out-Null
    Set-StreamMode
}
# Same bounds as display.rs parse_mode.
function Set-StreamMode {
    if ($StreamMode -eq '-') { Remove-ItemProperty -Path $ModeKey -Name 'StreamMode' -ErrorAction SilentlyContinue; return }
    if (-not $StreamMode) { return }
    $w, $h, $hz = [int[]]($StreamMode -split '[x@]')
    if ($w -lt 1280 -or $w -gt 7680 -or $h -lt 720 -or $h -gt 4320 -or $hz -lt 24 -or $hz -gt 500) { throw "stream mode out of range: $StreamMode" }
    New-ItemProperty -Path $ModeKey -Name 'StreamMode' -Value $StreamMode -PropertyType String -Force | Out-Null
}
function Get-StreamMode { if (Test-Path $ModeKey) { (Get-ItemProperty -Path $ModeKey -Name 'StreamMode' -ErrorAction SilentlyContinue).StreamMode } }

# The agent owns its profile and could plant a junction to redirect an administrator's write: links are removed unfollowed.
function Initialize-ProfileFolder([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $item.PSIsContainer) {
            if ($item.PSIsContainer) { & cmd.exe /c rmdir "$Path" } else { & cmd.exe /c del /f /q /a "$Path" }
            $notes.Add("removed a link at $Path")
        }
    }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Path is still a link" }
}

# CreateNew never follows or reuses an existing name (a link or hard link).
function Write-NewFile([string]$Path, [string]$Text) {
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.PSIsContainer) { & cmd.exe /c rmdir "$Path" } else { $item.Attributes = 'Normal'; & cmd.exe /c del /f /q /a "$Path" }
        if (Test-Path -LiteralPath $Path) { throw "can't replace $Path" }
    }
    $fs = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $b = [Text.Encoding]::Unicode.GetPreamble() + [Text.Encoding]::Unicode.GetBytes($Text); $fs.Write($b, 0, $b.Length) }
    finally { $fs.Dispose() }
}

function Assert-Staging {
    if (-not $Staging -or -not (Test-Path -LiteralPath $Staging)) { throw "the staging folder $Staging doesn't exist" }
    $full = [IO.Path]::GetFullPath($Staging).TrimEnd('\')
    if (($full + '\').StartsWith($DataDir + '\', 'OrdinalIgnoreCase')) {
        foreach ($p in (Split-Path $DataDir -Parent), $DataDir) { if (-not (Test-Trusted $p)) { throw "$p isn't safe (a link or owned by someone else)" } }
    }
    if (-not (Test-Trusted $full)) { throw "$full isn't safe (a link or owned by someone else)" }
    $exe = Join-Path $full 'gpuvm-agent.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "gpuvm-agent.exe not found in $full" }
    if (-not (Test-Trusted $exe)) { throw "$exe isn't safe (a link or owned by someone else)" }
    if ($ExpectedSha256 -and (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $ExpectedSha256.ToUpperInvariant()) { throw "$exe doesn't match the expected SHA-256" }
    $exe
}

function Remove-SecretFile {
    $f = Join-Path $DataDir 'secret'
    if (Test-Path -LiteralPath $f) {
        $junk = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($junk)
        [IO.File]::WriteAllBytes($f, $junk)
        Remove-Item -LiteralPath $f -Force
    }
}

# The service's helpers in the sign-in sessions run from the same exe and can outlive it for a moment.
function Stop-Agent {
    $s = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($s -and $s.Status -ne 'Stopped') { Stop-Service -Name $ServiceName -Force }
    $deadline = (Get-Date).AddSeconds(15)
    while ($true) {
        $left = @(Get-CimInstance Win32_Process -Filter "Name = 'gpuvm-agent.exe'" | Where-Object { $_.ExecutablePath -and $_.ExecutablePath -ieq $Exe })
        if (-not $left.Count) { return }
        if ((Get-Date) -gt $deadline) { $left | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; Start-Sleep -Milliseconds 500; return }
        Start-Sleep -Milliseconds 250
    }
}

if ($Uninstall) {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        Stop-Agent
        & sc.exe delete $ServiceName | Out-Null
    }
    if (Test-Path $AppDir) { Remove-Item -LiteralPath $AppDir -Recurse -Force }
    if (Test-Path $DataDir) { Remove-Item -LiteralPath $DataDir -Recurse -Force }
    $restored = Restore-PreviousAutologon
    foreach ($p in $MachinePolicies) { Restore-Value $p.Path $p.Name }
    $reboot = $false
    if ($RemoveUser -and (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
        $sid = (Get-LocalUser -Name $UserName).SID.Value
        $prof = Get-CimInstance Win32_UserProfile | Where-Object SID -eq $sid
        if ($prof -and $prof.Loaded) {
            $notes.Add('the agent user is signed in: its profile is removed after a restart and a new run of -Uninstall -RemoveUser')
            $reboot = $true
        } else {
            if ($prof) { $prof | Remove-CimInstance }
            Remove-LocalUser -Name $UserName
        }
    }
    if (Test-Path $ModeKey) { Remove-ItemProperty -Path $ModeKey -Name 'AgentSid', 'SignInAs', 'StreamMode' -ErrorAction SilentlyContinue }
    if ((Test-Path $BackupKey) -and -not (Get-Item $BackupKey).Property) { Remove-Item 'HKLM:\SOFTWARE\GpuVM\Agent' -Recurse -Force }
    [pscustomobject]@{ ok = $true; uninstalled = $true; autologonRestored = $restored; rebootNeeded = ($reboot -or $restored); notes = @($notes) }
    return
}

function Remove-Staging {
    if ($Staging -and (Test-Path $Staging) -and ([IO.Path]::GetFullPath($Staging) + '\').StartsWith($DataDir + '\', 'OrdinalIgnoreCase')) {
        Remove-Item -LiteralPath $Staging -Recurse -Force
    }
}

if ($PrepareTemplate) {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) { Stop-Agent }
    Remove-SecretFile
    Remove-Item -LiteralPath (Join-Path $DataDir 'logs') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Staging
    # No password travels in a template.
    [GpuVMAgentLsa]::Store('DefaultPassword', $null)
    [GpuVMAgentLsa]::Store($PrevSecret, $null)
    [GpuVMAgentLsa]::Store($PrevPlainSecret, $null)
    if (Test-Path $BackupKey) {
        $b = Get-Item $BackupKey
        foreach ($n in @($b.Property | Where-Object { $_ -like '*Winlogon|*' -or $_ -like 'LSA|*' -or $_ -like 'PLAIN|*' })) { Remove-ItemProperty -Path $BackupKey -Name $n }
    }
    Set-Value $Winlogon 'AutoAdminLogon' '0' 'String'
    if (Test-Path $ModeKey) { Remove-ItemProperty -Path $ModeKey -Name 'StreamMode' -ErrorAction SilentlyContinue }
    [pscustomobject]@{ ok = $true; template = $true; secret = 'removed'; passwords = 'removed'
        notes = @('a copy signs in as agent only after its install (new secret + new agent password) and a restart') }
    return
}

if ($Secret -and $Secret.Length -ne 32) { throw 'the secret must be 32 bytes' }
$srcExe = Assert-Staging
$newVersion = (& $srcExe version 2>$null | Out-String).Trim()

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
$oldVersion = if (Test-Path $Exe) { (& $Exe version 2>$null | Out-String).Trim() } else { '' }
if (-not $Full -and $svc -and $user -and $SignInAs -eq 'agent' -and $oldVersion -and $oldVersion -eq $newVersion) {
    Stop-Agent
    Initialize-DataDir
    if ($Secret) { [IO.File]::WriteAllBytes((Join-Path $DataDir 'secret'), $Secret) }
    Set-ProtectedAcl $DataDir $false
    $password = New-Password
    Set-LocalUser -Name $UserName -Password (ConvertTo-SecureString $password -AsPlainText -Force)
    $before = "$(Get-Reg $Winlogon 'AutoAdminLogon')|$(Get-Reg $Winlogon 'DefaultUserName')"
    Set-AgentAutologon $password
    Set-AgentMode $user.SID.Value 'agent'
    # A template's copy sits at the sign-in screen: it needs the restart to sign in.
    $console = "$((Get-CimInstance Win32_ComputerSystem).UserName)"
    $restart = ($before -ne "1|$UserName") -or ($console -notlike "*\$UserName")
    Start-Service -Name $ServiceName
    Remove-Staging
    [pscustomobject]@{
        ok = $true; version = $newVersion; user = $UserName; password = $password; signInAs = 'agent'
        secret = $(if (Test-Path (Join-Path $DataDir 'secret')) { 'present' } else { 'missing' })
        rebootNeeded = $restart; fastPath = $true; streamMode = (Get-StreamMode); notes = @()
    }
    return
}

Initialize-DataDir
if ($Secret) {
    [IO.File]::WriteAllBytes((Join-Path $DataDir 'secret'), $Secret)
    Set-ProtectedAcl $DataDir $false
}

if ($svc) { Stop-Agent }
if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory -Path $AppDir -Force | Out-Null }
Copy-Item -LiteralPath $srcExe -Destination $Exe -Force
Set-ProtectedAcl $AppDir $true
$version = (& $Exe version 2>$null | Out-String).Trim()
if (-not $svc) {
    New-Service -Name $ServiceName -BinaryPathName "`"$Exe`" service" -DisplayName 'GpuVM Agent' `
        -Description 'Lets GpuVM on the host drive this machine for AI agents (screen, input, UI Automation, commands as the agent user). Approvals stay with the person.' `
        -StartupType Automatic | Out-Null
}
& sc.exe failure $ServiceName reset= 86400 actions= restart/2000/restart/2000/restart/10000 | Out-Null

$password = New-Password
$secure = ConvertTo-SecureString $password -AsPlainText -Force
$user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
if (-not $user) {
    $user = New-LocalUser -Name $UserName -Password $secure -FullName 'GpuVM Agent' -Description 'Account for AI agents in GpuVM' `
        -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires
} else {
    Set-LocalUser -Name $UserName -Password $secure -PasswordNeverExpires $true
    if (-not $user.Enabled) { Enable-LocalUser -Name $UserName }
}
$sid = $user.SID.Value
if (-not (Get-LocalGroupMember -SID $SidUsers.Value -ErrorAction SilentlyContinue | Where-Object { $_.SID.Value -eq $sid })) {
    Add-LocalGroupMember -SID $SidUsers.Value -Member $sid
}
if (Get-LocalGroupMember -SID $SidAdmins.Value -ErrorAction SilentlyContinue | Where-Object { $_.SID.Value -eq $sid }) {
    Remove-LocalGroupMember -SID $SidAdmins.Value -Member $sid
    $notes.Add('the agent user was an administrator: removed from Administrators')
}

$profilePath = Get-AgentProfile $sid
if (-not $profilePath) {
    # A leftover C:\Users\agent with no profile would make Windows pick C:\Users\agent.000.
    $profilesDir = [Environment]::ExpandEnvironmentVariables((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList').ProfilesDirectory)
    $wanted = Join-Path $profilesDir $UserName
    if (Test-Path -LiteralPath $wanted) {
        $aside = "$wanted.orphan-$(Get-Date -Format yyyyMMddHHmmss)"
        Rename-Item -LiteralPath $wanted -NewName (Split-Path $aside -Leaf)
        $notes.Add("moved a leftover $wanted aside to $aside")
    }
    $sb = New-Object Text.StringBuilder 260
    $hr = [GpuVMAgentProfile]::CreateProfile($sid, $UserName, $sb, 260)
    if ($hr -ne 0 -and $hr -ne -2147024713) { throw ('CreateProfile failed: 0x{0:X8}' -f $hr) }   # 0x800700B7 = exists
    $profilePath = Get-AgentProfile $sid
}
if (-not $profilePath -or -not (Test-Path $profilePath)) { throw "the agent's profile folder wasn't created" }

$spanish = [Globalization.CultureInfo]::InstalledUICulture.TwoLetterISOLanguageName -eq 'es'
$desktop = Join-Path $profilePath 'Desktop'
Initialize-ProfileFolder $desktop
$owned = New-Object Collections.Generic.List[string]
$owned.Add($desktop)
foreach ($f in @(@{ Name = 'Received'; Es = 'Recibidos' }, @{ Name = 'Outbox'; Es = 'Entregas' })) {
    $dir = Join-Path $desktop $f.Name
    Initialize-ProfileFolder $dir
    $owned.Add($dir)
    $ini = Join-Path $dir 'desktop.ini'
    if ($spanish) {
        Write-NewFile $ini "[.ShellClassInfo]`r`nLocalizedResourceName=$($f.Es)`r`n"
        [IO.File]::SetAttributes($ini, [IO.FileAttributes]'Hidden, System')
        $owned.Add($ini)
        (Get-Item -LiteralPath $dir -Force).Attributes = 'ReadOnly, Directory'   # Explorer reads desktop.ini only for read-only/system folders
    } elseif (Test-Path -LiteralPath $ini) {
        Write-NewFile $ini ''; Remove-Item -LiteralPath $ini -Force
    }
}
# Exactly these paths: never recursive, never through a link (/L).
foreach ($p in $owned) { & icacls.exe $p /setowner "*$sid" /L /C /Q | Out-Null }

Invoke-AgentHive $sid $profilePath {
    param($root)
    $edge = "$root\SOFTWARE\Policies\Microsoft\Edge"
    Set-Value $edge 'HideFirstRunExperience' 1
    Set-Value $edge 'DefaultBrowserSettingEnabled' 0
    Set-Value $edge 'PromotionalTabsEnabled' 0
    Set-Value $edge 'ShowRecommendationsEnabled' 0
    Set-Value $edge 'BrowserSignin' 0
    Set-Value "$root\Control Panel\Desktop" 'UserPreferencesMask' ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)) 'Binary'
    Set-Value "$root\Control Panel\Desktop" 'DragFullWindows' '0' 'String'
    Set-Value "$root\Control Panel\Desktop" 'MenuShowDelay' '0' 'String'
    Set-Value "$root\Control Panel\Desktop" 'ScreenSaveActive' '0' 'String'
    Set-Value "$root\Control Panel\Desktop" 'CursorBlinkRate' '-1' 'String'   # a steady caret: screenshots don't flicker
    Set-Value "$root\Control Panel\Desktop\WindowMetrics" 'MinAnimate' '0' 'String'
    Set-Value "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" 'VisualFXSetting' 2
    # Windows' banners (a device being set up, OneDrive's offers) take the focus: the agent's keys would land there.
    Set-Value "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications" 'ToastEnabled' 0
    $adv = "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-Value $adv 'TaskbarAnimations' 0
    Set-Value $adv 'ListviewAlphaSelect' 0
    Set-Value $adv 'ListviewShadow' 0
    Set-Value "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" 'EnableTransparency' 0
    Set-Value "$root\SOFTWARE\Microsoft\Windows\DWM" 'EnableAeroPeek' 0
    $cdm = "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    foreach ($n in 'SubscribedContent-310093Enabled', 'SubscribedContent-338389Enabled', 'SoftLandingEnabled', 'SystemPaneSuggestionsEnabled') { Set-Value $cdm $n 0 }
    Set-Value "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement" 'ScoobeSystemSettingEnabled' 0
}

foreach ($p in $MachinePolicies) {
    Backup-Value $p.Path $p.Name
    Set-Value $p.Path $p.Name $p.Value
}

Set-AgentMode $sid $SignInAs
$reboot = $false
if ($SignInAs -eq 'agent') {
    $before = "$(Get-Reg $Winlogon 'AutoAdminLogon')|$(Get-Reg $Winlogon 'DefaultUserName')"
    Set-AgentAutologon $password
    $reboot = $before -ne "1|$UserName"
} else {
    $reboot = Restore-PreviousAutologon
}

Start-Service -Name $ServiceName
$secretState = if (Test-Path (Join-Path $DataDir 'secret')) { 'present' } else { 'missing' }
if ($secretState -eq 'missing') { $notes.Add("copy the 32-byte secret to $DataDir\secret (Copy-VMFile); the service dials the host once it is there") }

[pscustomobject]@{
    ok = $true
    version = $version
    user = $UserName
    password = $password
    signInAs = $SignInAs
    secret = $secretState
    rebootNeeded = $reboot
    fastPath = $false
    streamMode = (Get-StreamMode)
    notes = @($notes)
}
Remove-Staging
