# Finishes the template remake when "<name>-next" exists and the base VM is left (make-tpl.ps1 stopped after the
# first copy because New-GpuVMTemplate -ShutdownIfRunning starts the VM again): start the base, prepare it again (its
# service wrote logs on that boot), check no password is left, save it as <name>, then remove <name>-next and the base.
# One lab lock.
param([string]$Name = 'agent-base', [string]$Template = 'agent-tpl', [string]$Me = 'agent-guest')
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
function Step($m) { "[$(Get-Date -Format HH:mm:ss)] $m" | Out-Host }
& (Join-Path $repo 'labs\042-admin-dock\take-lock.ps1') -What "lab 051: finish $Template from $Name" -Me $Me -MaxMinutes 60
if ($LASTEXITCODE -ne 0) { throw 'no lock' }
try {
    $cred = Import-Clixml (Join-Path $PSScriptRoot "out\$Name.xml")
    if ((Get-VM -Name $Name).State -ne 'Running') { Start-VM -Name $Name }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do { Start-Sleep -Seconds 2; $ok = try { Invoke-Command -VMName $Name -Credential $cred -ErrorAction Stop { $true } } catch { $false } } until ($ok -or $sw.Elapsed.TotalMinutes -gt 5)
    if (-not $ok) { throw 'PowerShell Direct never answered' }
    $installText = Get-Content (Join-Path $repo 'guest\agent\install.ps1') -Raw
    $prep = Invoke-Command -VMName $Name -Credential $cred ([scriptblock]::Create("& { $installText } -PrepareTemplate"))
    $left = Invoke-Command -VMName $Name -Credential $cred {
        Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class L51F { [StructLayout(LayoutKind.Sequential)] struct U { public ushort L; public ushort M; public IntPtr B; } [StructLayout(LayoutKind.Sequential)] struct A { public int Len; public IntPtr R; public IntPtr N; public uint At; public IntPtr S; public IntPtr Q; } [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr s, ref A a, uint acc, out IntPtr h); [DllImport("advapi32.dll")] static extern uint LsaRetrievePrivateData(IntPtr h, ref U k, out IntPtr d); [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr p); [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr h); public static bool Has(string key) { var a = new A(); a.Len = Marshal.SizeOf(a); IntPtr h; LsaOpenPolicy(IntPtr.Zero, ref a, 4, out h); IntPtr m = Marshal.StringToHGlobalUni(key); var k = new U(); k.L = (ushort)(key.Length*2); k.M = (ushort)(key.Length*2+2); k.B = m; IntPtr d; uint r = LsaRetrievePrivateData(h, ref k, out d); bool has = false; if (r == 0) { has = Marshal.ReadInt16(d) > 0; LsaFreeMemory(d); } Marshal.FreeHGlobal(m); LsaClose(h); return has; } }' -ErrorAction SilentlyContinue
        $b = Get-Item 'HKLM:\SOFTWARE\GpuVM\Agent\Backup' -ErrorAction SilentlyContinue
        [pscustomobject]@{
            lsa = [L51F]::Has('DefaultPassword') -or [L51F]::Has('GpuVMAgent_PreviousDefaultPassword') -or [L51F]::Has('GpuVMAgent_PreviousPlainDefaultPassword')
            plain = [bool]((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').PSObject.Properties.Name -contains 'DefaultPassword')
            backup = @(if ($b) { $b.Property }) -join '; '
            data = @(Get-ChildItem C:\ProgramData\GpuVM\Agent -Force | ForEach-Object Name) -join ','
        }
    }
    Step "prepare ok=$($prep.ok); left: $($left | ConvertTo-Json -Compress)"
    if ($left.lsa -or $left.plain -or $left.backup -match 'Winlogon|LSA|PLAIN' -or $left.data -match 'secret|logs') { throw 'something is left: no template' }
    New-GpuVMTemplate -Name $Template -VMName $Name -ShutdownIfRunning -Confirm:$false | Out-Null
    $t = Get-GpuVMTemplate | Where-Object Name -eq $Template
    if (-not $t) { throw "$Template wasn't created" }
    $json = Get-Content "C:\GpuVM\.templates\$Template\template.json" -Raw | ConvertFrom-Json
    Step "template $Template : $($t.fileGB) GB, use=$($json.use), agentSignInAs=$($json.agentSignInAs)"
    Remove-GpuVMTemplate -Name "$Template-next" -Confirm:$false | Out-Null
    Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue
    Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false | Out-Null
    Step "removed $Template-next and $Name; templates: $((Get-GpuVMTemplate | ForEach-Object Name) -join ', ')"
}
finally {
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Step 'lock released'
}
