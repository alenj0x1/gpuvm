# Remakes the shared template `agent-tpl` the right way, with the INSTALLED GpuVM only, under ONE lab lock:
# 1. a fresh VM from the ISO; its own account (gpuvm) finishes the first sign-in and guest\setup.ps1
#    (C:\GpuVM\setup.done.json written, no reboot pending, Sunshine running);
# 2. Install-GpuVMAgent (the broker's path), restart from inside, real sign-in as `agent`, the agent connected, the
#    display it works on and one screenshot (agent.info + screen.capture through the broker);
# 3. install.ps1 -PrepareTemplate (no secret, no logs), checked; New-GpuVMTemplate agent-tpl; the VM is removed.
# Run elevated. The old agent-tpl is deleted first.
param([string]$Name = 'agent-base', [string]$Template = 'agent-tpl', [string]$Me = 'agent-guest',
    [string]$IsoPath = 'C:\Users\you\Downloads\Win10_22H2_Spanish_Mexico_x64v1.iso', [switch]$Resume)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null
Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
function Step($m) { "[$(Get-Date -Format HH:mm:ss)] $m" | Out-Host }   # no -f: messages carry JSON braces
function Guest([scriptblock]$Sb) { Invoke-Command -VMName $Name -Credential $cred -ErrorAction Stop -ScriptBlock $Sb }
function Wait-For([string]$What, [scriptblock]$Ok, [int]$Minutes) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalMinutes -lt $Minutes) {
        $v = try { & $Ok } catch { $null }
        if ($v) { Step "$What after $([int]$sw.Elapsed.TotalSeconds) s"; return $v }
        if ((Get-VM -Name $Name).State -ne 'Running') { throw "$Name is $((Get-VM -Name $Name).State) while waiting: $What" }
        Start-Sleep -Seconds 3
    }
    throw "timeout ($Minutes min): $What"
}

& (Join-Path $repo 'labs\042-admin-dock\take-lock.ps1') -What "lab 051: remake $Template from a fresh $Name (one lock)" -Me $Me -MaxMinutes 180
if ($LASTEXITCODE -ne 0) { throw 'no lock' }
$keep = $false
try {
    if ($Resume -and (Get-VM -Name $Name -ErrorAction SilentlyContinue)) {
        # the base VM from a run that failed after its first setup: reuse it (no agent installed on it yet)
        $cred = Import-Clixml (Join-Path $out "$Name.xml")
        if ((Get-VM -Name $Name).State -ne 'Running') { Start-VM -Name $Name }
        Step 'resuming with the existing base VM'
    } else {
        if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Stop-VM -Name $Name -TurnOff -Force; Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false | Out-Null }
        # 1. fresh VM, its own account's first sign-in + setup.ps1
        $bytes = [byte[]]::new(18); [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $pw = 'Lb7!' + [Convert]::ToBase64String($bytes).Replace('/', 'x').Replace('+', 'y')
        $cred = [pscredential]::new('gpuvm', (ConvertTo-SecureString $pw -AsPlainText -Force))
        $cred | Export-Clixml (Join-Path $out "$Name.xml")
        New-GpuVM -Name $Name -IsoPath $IsoPath -Credential $cred -Override @{ vm = @{ memoryGB = 4; cpu = @{ count = 4 }; disk = @{ sizeGB = 64 } } } -Confirm:$false | Out-Null
        Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes 4GB
        Start-VM -Name $Name
        Step 'created and started'
    }
    $done = Wait-For 'setup.done.json without a pending reboot, gpuvm signed in, Sunshine running' {
        $s = Guest {
            $p = 'C:\GpuVM\setup.done.json'
            $j = if (Test-Path $p) { Get-Content -Raw $p | ConvertFrom-Json } else { $null }
            $pending = if ($j -and $j.PSObject.Properties['rebootPending']) { [bool]$j.rebootPending } else { $true }
            $rebooted = (Test-Path $p) -and ((Get-CimInstance Win32_OperatingSystem).LastBootUpTime -gt (Get-Item $p).LastWriteTime)
            [pscustomobject]@{
                done = [bool]$j -and (-not $pending -or $rebooted)
                user = (Get-CimInstance Win32_ComputerSystem).UserName
                sunshine = "$((Get-Service SunshineService -ErrorAction SilentlyContinue).Status)"
            }
        }
        # gpuvm on a fresh VM; agent when resuming a base VM the agent was already installed on
        if ($s.done -and ($s.user -like '*\gpuvm' -or ($Resume -and $s.user -like '*\agent')) -and $s.sunshine -eq 'Running') { $s } else { $null }
    } 40
    Step "first setup: $($done | ConvertTo-Json -Compress)"

    # 2. the agent through the broker, then a real sign-in as agent
    $inst = Install-GpuVMAgent -Name $Name
    Step "Install-GpuVMAgent: $($inst | ConvertTo-Json -Compress -Depth 4)"
    if (-not $inst.restarted) { Guest { Restart-Computer -Force } }   # Install-GpuVMAgent restarts it itself when needed
    Start-Sleep -Seconds 10
    Wait-For 'signed in as agent after the restart' { $u = Guest { (Get-CimInstance Win32_ComputerSystem).UserName }; if ($u -like '*\agent') { $u } } 8 | Out-Null
    $info = Wait-For 'agent connected and signed in (through the broker)' { $r = Invoke-GpuVMAgent -Name $Name -Method agent.info -TimeoutSec 5; if ($r.ok -and $r.result.signedIn) { $r } } 5
    Step "agent.info: $($info.result | ConvertTo-Json -Compress -Depth 4)"
    # right after sign-in the input desktop is still Winlogon's (captures refused secure_desktop, lab 051): wait for
    # the normal desktop with the agent's display arranged (only the virtual one)
    Wait-For 'normal desktop, only the virtual display' {
        $st = Invoke-GpuVMAgent -Name $Name -Method screen.state -TimeoutSec 5
        $ai = Invoke-GpuVMAgent -Name $Name -Method agent.info -TimeoutSec 5
        if ($st.ok -and $st.result.desktop -eq 'default' -and @($ai.result.displays).Count -eq 1) { $st }
    } 3 | Out-Null
    $shot = Wait-For 'a screenshot' { $c = Invoke-GpuVMAgent -Name $Name -Method screen.capture -Params @{ format = 'webp' }; if ($c.ok) { $c } } 1
    if ($shot.ok) { Copy-Item $shot.blobPath (Join-Path $out "$Template-check.$($shot.blobFormat)") }
    Step "screen.capture: ok=$($shot.ok) $($shot.result | ConvertTo-Json -Compress -Depth 4) $($shot.error | ConvertTo-Json -Compress)"
    if (-not $shot.ok) { throw 'no screenshot: not making a template from this' }

    # 3. no secret, no logs; template
    $installText = Get-Content (Join-Path $repo 'guest\agent\install.ps1') -Raw
    $prep = Guest ([scriptblock]::Create("& { $installText } -PrepareTemplate"))
    $left = Guest { @(Get-ChildItem C:\ProgramData\GpuVM\Agent -Force | ForEach-Object Name) -join ',' }
    Step "prepare: $($prep | ConvertTo-Json -Compress); left: '$left'"
    if ($left -match 'secret') { throw 'the secret is still there: no template' }
    # no password may travel in the template: checked in the base before copying it
    $leftPw = Guest {
        Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class L51T { [StructLayout(LayoutKind.Sequential)] struct U { public ushort L; public ushort M; public IntPtr B; } [StructLayout(LayoutKind.Sequential)] struct A { public int Len; public IntPtr R; public IntPtr N; public uint At; public IntPtr S; public IntPtr Q; } [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr s, ref A a, uint acc, out IntPtr h); [DllImport("advapi32.dll")] static extern uint LsaRetrievePrivateData(IntPtr h, ref U k, out IntPtr d); [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr p); [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr h); public static bool Has(string key) { var a = new A(); a.Len = Marshal.SizeOf(a); IntPtr h; LsaOpenPolicy(IntPtr.Zero, ref a, 4, out h); IntPtr m = Marshal.StringToHGlobalUni(key); var k = new U(); k.L = (ushort)(key.Length*2); k.M = (ushort)(key.Length*2+2); k.B = m; IntPtr d; uint r = LsaRetrievePrivateData(h, ref k, out d); bool has = false; if (r == 0) { has = Marshal.ReadInt16(d) > 0; LsaFreeMemory(d); } Marshal.FreeHGlobal(m); LsaClose(h); return has; } }' -ErrorAction SilentlyContinue
        $b = Get-Item 'HKLM:\SOFTWARE\GpuVM\Agent\Backup' -ErrorAction SilentlyContinue
        [pscustomobject]@{
            lsaDefaultPassword = [L51T]::Has('DefaultPassword'); lsaPrevious = [L51T]::Has('GpuVMAgent_PreviousDefaultPassword'); lsaPrevPlain = [L51T]::Has('GpuVMAgent_PreviousPlainDefaultPassword')
            plainWinlogonPassword = [bool]((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').PSObject.Properties.Name -contains 'DefaultPassword')
            backup = @(if ($b) { $b.Property }) -join '; '
            agentSid = (Get-ItemProperty 'HKLM:\SOFTWARE\GpuVM\Agent' -ErrorAction SilentlyContinue).AgentSid
        }
    }
    Step "passwords left in the base: $($leftPw | ConvertTo-Json -Compress)"
    if ($leftPw.lsaDefaultPassword -or $leftPw.lsaPrevious -or $leftPw.lsaPrevPlain -or $leftPw.plainWinlogonPassword -or $leftPw.backup -match 'Winlogon|LSA|PLAIN') { throw 'a password is still in the base: no template' }
    # the new template exists before the old one goes: made as "<name>-next", then the old one is replaced
    $next = "$Template-next"
    if (Get-GpuVMTemplate | Where-Object Name -eq $next) { Remove-GpuVMTemplate -Name $next -Confirm:$false | Out-Null }
    New-GpuVMTemplate -Name $next -VMName $Name -ShutdownIfRunning -Confirm:$false | Out-Null
    $t = Get-GpuVMTemplate | Where-Object Name -eq $next
    Step "template ${next}: $($t | ConvertTo-Json -Compress -Depth 4)"
    if (-not $t) { throw "$next wasn't created" }
    if (Get-GpuVMTemplate | Where-Object Name -eq $Template) { Remove-GpuVMTemplate -Name $Template -Confirm:$false | Out-Null; Step "old $Template deleted" }
    New-GpuVMTemplate -Name $Template -VMName $Name -Confirm:$false | Out-Null
    $t = Get-GpuVMTemplate | Where-Object Name -eq $Template
    if (-not $t) { throw "$Template wasn't created ($next is kept)" }
    Remove-GpuVMTemplate -Name $next -Confirm:$false | Out-Null
    Step "template $Template created: $($t | ConvertTo-Json -Compress -Depth 4)"
}
catch { Step "FAILED: $($_.Exception.Message)"; $keep = $true; throw }
finally {
    # the base VM is not needed once the template exists (its 64 GB reservation blocks other machines)
    if (-not $keep -and (Get-VM -Name $Name -ErrorAction SilentlyContinue)) {
        Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue
        Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Step "$Name removed"
    }
    if ($keep -and (Get-VM -Name $Name -ErrorAction SilentlyContinue)) { Stop-VM -Name $Name -Force -ErrorAction SilentlyContinue; Step "$Name kept (Off) for diagnosis" }
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Step 'lock released'
}
