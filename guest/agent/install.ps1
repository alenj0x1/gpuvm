<#
.SYNOPSIS
    Prepares a Windows guest for GpuVM's "Agent" usage type, or undoes it. Run once by the host broker over PowerShell
    Direct as an administrator of the guest (Windows PowerShell 5.1). Idempotent: running it again updates the agent
    and rotates the agent user's password.

.DESCRIPTION
    - Installs gpuvm-agent.exe under C:\Program Files\GpuVM Agent (Administrators/SYSTEM write, Users read+execute)
      and the GpuVMAgent service (SYSTEM, automatic, restarts on failure).
    - Creates C:\ProgramData\GpuVM\Agent with an ACL of SYSTEM + Administrators only (the service refuses anything
      else), for the per-VM secret and the logs. The secret comes from -Secret or is copied later by the host with
      Copy-VMFile into that folder (it inherits the ACL).
    - Creates the standard user `agent` (member of Users only, never Administrators) with a random password that is
      returned to the host, which keeps it with DPAPI; the guest keeps it only as the autologon LSA secret.
    - Signs in as `agent` automatically (Winlogon + LSA secret DefaultPassword, never the plain registry value). The
      previous autologon (the person's) is backed up, its password into another LSA secret, and restored by
      -SignInAs previous or -Uninstall.
    - In the agent's profile only: Desktop\Received and Desktop\Outbox (fixed English names, localized display names
      via desktop.ini), Edge first-run and promotions off by user policy, visual effects and animations off, screen
      saver off, Windows tips and "finish setting up" screens off.
    - Machine-wide, backed up and restored on uninstall: the new-user privacy screen and the first sign-in animation
      are skipped (they would block the agent's first sign-in). Nothing else of the person's user, data or UAC changes.

.OUTPUTS
    One object: ok, version, user, password (only when it was set this run), signInAs, secret, rebootNeeded, notes.
#>
[CmdletBinding()]
param(
    # folder that holds gpuvm-agent.exe (copied into the guest by the host)
    [string]$Source = $PSScriptRoot,
    # the per-VM secret (32 bytes); optional when the host copies it with Copy-VMFile afterwards
    [byte[]]$Secret,
    # who Windows signs in automatically: the agent user, or whatever was configured before (the person)
    [ValidateSet('agent', 'previous')][string]$SignInAs = 'agent',
    [switch]$Uninstall,
    # with -Uninstall: also delete the agent user and its profile
    [switch]$RemoveUser
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

# --- LSA secrets (the autologon password lives here, never in the plain registry) ---------------------------------
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

# --- small helpers ------------------------------------------------------------------------------------------------
function Set-Value([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }   # creates missing keys only; existing values stay
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

# Saves a machine value once (before the first change), so uninstall can put it back exactly; '<absent>' if it wasn't set.
function Backup-Value([string]$Path, [string]$Name) {
    $id = ($Path -replace '^HKLM:\\', '') + '|' + $Name
    if (-not (Test-Path $BackupKey)) { New-Item -Path $BackupKey -Force | Out-Null }
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
    # children too (files that were there before get the same protected rules)
    Get-ChildItem -LiteralPath $Path -Recurse -Force | ForEach-Object {
        $a = Get-Acl -LiteralPath $_.FullName
        $a.SetAccessRuleProtection($false, $false)
        foreach ($r in @($a.Access | Where-Object { -not $_.IsInherited })) { [void]$a.RemoveAccessRule($r) }
        $a.SetOwner($SidAdmins)
        Set-Acl -LiteralPath $_.FullName -AclObject $a
    }
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

# Runs $Script against the agent's registry hive (HKU\<sid> when signed in, else NTUSER.DAT loaded for the moment).
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

$WinlogonValues = 'AutoAdminLogon', 'DefaultUserName', 'DefaultDomainName', 'AutoLogonCount', 'DefaultPassword'

function Set-AgentAutologon([string]$Password) {
    foreach ($n in $WinlogonValues) { Backup-Value $Winlogon $n }
    # the previous autologon password (an LSA secret written by Windows setup) is kept in another LSA secret
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
    $true
}

$MachinePolicies = @(
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'; Name = 'DisablePrivacyExperience'; Value = 1 },
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'EnableFirstLogonAnimation'; Value = 0 }
)

# --- uninstall ----------------------------------------------------------------------------------------------------
if ($Uninstall) {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -ne 'Stopped') { Stop-Service -Name $ServiceName -Force }
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
    if ((Test-Path $BackupKey) -and -not (Get-Item $BackupKey).Property) { Remove-Item 'HKLM:\SOFTWARE\GpuVM\Agent' -Recurse -Force }
    [pscustomobject]@{ ok = $true; uninstalled = $true; autologonRestored = $restored; rebootNeeded = ($reboot -or $restored); notes = @($notes) }
    return
}

# --- install / update ---------------------------------------------------------------------------------------------
$srcExe = Join-Path $Source 'gpuvm-agent.exe'
if (-not (Test-Path $srcExe)) { throw "gpuvm-agent.exe not found in $Source" }
if ($Secret -and $Secret.Length -ne 32) { throw 'the secret must be 32 bytes' }

# 1. data folder: SYSTEM + Administrators only (checked again by the service before every connection)
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
Set-ProtectedAcl $DataDir $false
if ($Secret) {
    [IO.File]::WriteAllBytes((Join-Path $DataDir 'secret'), $Secret)
    Set-ProtectedAcl $DataDir $false
}

# 2. binaries + service
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne 'Stopped') { Stop-Service -Name $ServiceName -Force }
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

# 3. the agent user: standard (Users only), random password returned to the host
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

# 4. its profile, created now so its folders and settings exist before the first sign-in
$profilePath = Get-AgentProfile $sid
if (-not $profilePath) {
    $sb = New-Object Text.StringBuilder 260
    $hr = [GpuVMAgentProfile]::CreateProfile($sid, $UserName, $sb, 260)
    if ($hr -ne 0 -and $hr -ne -2147024713) { throw ('CreateProfile failed: 0x{0:X8}' -f $hr) }   # 0x800700B7 = exists
    $profilePath = Get-AgentProfile $sid
}
if (-not $profilePath -or -not (Test-Path $profilePath)) { throw "the agent's profile folder wasn't created" }

# 5. Desktop\Received and Desktop\Outbox, localized display names
$spanish = [Globalization.CultureInfo]::InstalledUICulture.TwoLetterISOLanguageName -eq 'es'
$desktop = Join-Path $profilePath 'Desktop'
if (-not (Test-Path $desktop)) { New-Item -ItemType Directory -Path $desktop -Force | Out-Null }
foreach ($f in @(@{ Name = 'Received'; Es = 'Recibidos' }, @{ Name = 'Outbox'; Es = 'Entregas' })) {
    $dir = Join-Path $desktop $f.Name
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $ini = Join-Path $dir 'desktop.ini'
    if ($spanish) {
        if (Test-Path $ini) { (Get-Item $ini -Force).Attributes = 'Normal' }
        [IO.File]::WriteAllText($ini, "[.ShellClassInfo]`r`nLocalizedResourceName=$($f.Es)`r`n", [Text.Encoding]::Unicode)
        (Get-Item $ini -Force).Attributes = 'Hidden, System'
        (Get-Item $dir).Attributes = 'ReadOnly, Directory'   # Explorer reads desktop.ini only for read-only/system folders
    } elseif (Test-Path $ini) {
        (Get-Item $ini -Force).Attributes = 'Normal'; Remove-Item $ini
    }
}
# the files belong to the agent (created by an administrator here, so give ownership back)
foreach ($p in @($desktop, (Join-Path $desktop 'Received'), (Join-Path $desktop 'Outbox'))) {
    & icacls.exe $p /setowner "*$sid" /T /C /Q | Out-Null
}

# 6. the agent's own settings (its registry hive; the person's user is not touched)
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

# 7. machine: skip the privacy screen and the animation of a new user's first sign-in (backed up)
foreach ($p in $MachinePolicies) {
    Backup-Value $p.Path $p.Name
    Set-Value $p.Path $p.Name $p.Value
}

# 8. who signs in automatically
$reboot = $false
if ($SignInAs -eq 'agent') {
    $before = "$(Get-Reg $Winlogon 'AutoAdminLogon')|$(Get-Reg $Winlogon 'DefaultUserName')"
    Set-AgentAutologon $password
    $reboot = $before -ne "1|$UserName"
} else {
    $reboot = Restore-PreviousAutologon
}

# 9. start (the service waits for the secret if the host hasn't copied it yet)
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
    notes = @($notes)
}
