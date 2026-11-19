# Checks install.ps1's reversible parts inside the lab VM without restarting it: switches the automatic sign-in back to
# the previous user (-SignInAs previous), then to the agent again, and reports Winlogon, which LSA secrets exist
# (never their values), the backup key and the machine policies after each step. Optionally a full -Uninstall
# followed by a fresh install. Run elevated with the lab lock held.
param([string]$Name = 'agent051', [switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$cred = Import-Clixml (Join-Path $PSScriptRoot 'out\guest.xml')
$install = [scriptblock]::Create((Get-Content (Join-Path $root 'guest\agent\install.ps1') -Raw))
$probe = {
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class Lab051Lsa {
    [StructLayout(LayoutKind.Sequential)] struct U { public ushort L; public ushort M; public IntPtr B; }
    [StructLayout(LayoutKind.Sequential)] struct A { public int Len; public IntPtr R; public IntPtr N; public uint At; public IntPtr S; public IntPtr Q; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr s, ref A a, uint acc, out IntPtr h);
    [DllImport("advapi32.dll")] static extern uint LsaRetrievePrivateData(IntPtr h, ref U k, out IntPtr d);
    [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr p);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr h);
    public static bool Exists(string key) {
        var a = new A(); a.Len = Marshal.SizeOf(a); IntPtr h; LsaOpenPolicy(IntPtr.Zero, ref a, 4, out h);
        IntPtr m = Marshal.StringToHGlobalUni(key); var k = new U(); k.L = (ushort)(key.Length*2); k.M = (ushort)(key.Length*2+2); k.B = m;
        IntPtr d; uint s = LsaRetrievePrivateData(h, ref k, out d); if (s == 0) LsaFreeMemory(d); Marshal.FreeHGlobal(m); LsaClose(h); return s == 0;
    }
}
'@ -ErrorAction SilentlyContinue
    $w = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $b = Get-ItemProperty 'HKLM:\SOFTWARE\GpuVM\Agent\Backup' -ErrorAction SilentlyContinue
    [pscustomobject]@{
        AutoAdminLogon = $w.AutoAdminLogon; DefaultUserName = $w.DefaultUserName; DefaultDomainName = $w.DefaultDomainName
        AutoLogonCount = $w.AutoLogonCount; PlainDefaultPassword = [bool]($w.PSObject.Properties.Name -contains 'DefaultPassword')
        LsaDefaultPassword = [Lab051Lsa]::Exists('DefaultPassword'); LsaPrevious = [Lab051Lsa]::Exists('GpuVMAgent_PreviousDefaultPassword')
        BackupEntries = if ($b) { @($b.PSObject.Properties | ? Name -notlike 'PS*' | % { "$($_.Name)=$(if ($_.Name -like 'LSA*') { $_.Value } else { ($_.Value -split '\|')[0] })" }) -join '; ' } else { '<none>' }
        OOBE = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' -ErrorAction SilentlyContinue).DisablePrivacyExperience
        Service = (Get-Service GpuVMAgent -ErrorAction SilentlyContinue).Status
        AgentUser = [bool](Get-LocalUser agent -ErrorAction SilentlyContinue)
    }
}
$s = New-PSSession -VMName $Name -Credential $cred
try {
    $exeDir = 'C:\Windows\Temp\gpuvm-agent-setup'
    Invoke-Command -Session $s { param($d) New-Item -ItemType Directory $d -Force | Out-Null } -ArgumentList $exeDir
    Copy-Item (Join-Path $root 'guest\agent\target\release\gpuvm-agent.exe') -Destination $exeDir -ToSession $s -Force
    'before'; Invoke-Command -Session $s $probe | Format-List
    $r = Invoke-Command -Session $s $install -ArgumentList $exeDir, $null, 'previous'
    "previous: rebootNeeded=$($r.rebootNeeded)"; Invoke-Command -Session $s $probe | Format-List
    $r = Invoke-Command -Session $s $install -ArgumentList $exeDir, $null, 'agent'
    [pscredential]::new('agent', (ConvertTo-SecureString $r.password -AsPlainText -Force)) | Export-Clixml (Join-Path $PSScriptRoot 'out\agent.xml')
    "agent again: rebootNeeded=$($r.rebootNeeded)"; Invoke-Command -Session $s $probe | Format-List
    if ($Uninstall) {
        $u = Invoke-Command -Session $s { param($sb) & ([scriptblock]::Create($sb)) -Uninstall } -ArgumentList $install.ToString()
        "uninstall: $($u | ConvertTo-Json -Compress)"; Invoke-Command -Session $s $probe | Format-List
    }
}
finally {
    Invoke-Command -Session $s { param($d) Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } -ArgumentList 'C:\Windows\Temp\gpuvm-agent-setup'
    Remove-PSSession $s
}
