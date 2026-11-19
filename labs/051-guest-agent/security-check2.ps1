# The second security review's fixes, in a disposable from agent-tpl, one lab lock:
# 1. as the agent user, plant a junction Desktop\Outbox -> C:\Program Files\GpuVM Agent; install guest/agent/dist
#    (full path): the junction must be removed, the Program Files folder must keep its owner (Administrators).
# 2. the new agent connects; only the virtual display is active; Notepad opened by the agent is in its screenshot.
# 3. osk.exe (UIAccess) started by the agent: input under its window and with it in front must be refused.
# 4. install.ps1 -PrepareTemplate: no autologon password, no backed-up person password, no Winlogon backup, no secret;
#    then the fast path (as on a copy) must ask for a restart, and after it the VM signs in as agent again.
# The disposable is deleted at the end.
param([string]$Template = 'agent-tpl', [string]$Name = 'agent051-sec', [string]$Me = 'agent-guest')
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$outDir = Join-Path $PSScriptRoot ('out\security2-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $outDir | Out-Null
Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
$install = Join-Path $repo 'guest\agent\install.ps1'
$staging = 'C:\ProgramData\GpuVM\Agent\staging'
function Step($m) { "[$(Get-Date -Format HH:mm:ss)] $m" | Out-Host }
function Call([string]$Method, [hashtable]$P = @{}, [int]$T = 30) { Invoke-GpuVMAgent -Name $Name -Method $Method -Params $P -TimeoutSec $T }
function Wait-Agent([string]$Version) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalMinutes -lt 8) {
        $r = try { Call 'agent.info' @{} 5 } catch { $null }
        if ($r -and $r.ok -and $r.result.signedIn -and (-not $Version -or $r.result.version -eq $Version)) { return $r.result }
        Start-Sleep -Seconds 1
    }
    throw "agent $Version not ready"
}
# Runs a command line as the agent user in its session (one-shot interactive task), waits for it.
function As-Agent([string]$CmdLine) {
    Invoke-Command -Session $s {
        param($c)
        $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c $c"
        $p = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\agent" -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName Lab051Sec -Action $a -Principal $p -Force | Out-Null
        Start-ScheduledTask -TaskName Lab051Sec
        $t = 0; do { Start-Sleep -Milliseconds 300; $t++ } while ((Get-ScheduledTask -TaskName Lab051Sec).State -eq 'Running' -and $t -lt 60)
        Unregister-ScheduledTask -TaskName Lab051Sec -Confirm:$false
    } -ArgumentList $CmdLine
}
function Copy-Dist {
    Invoke-Command -Session $s { param($d) New-Item -ItemType Directory $d -Force | Out-Null } -ArgumentList $staging
    Get-ChildItem (Join-Path $repo 'guest\agent\dist') | ForEach-Object { Copy-Item $_.FullName -Destination $staging -ToSession $s -Force }
}

& (Join-Path $repo 'labs\042-admin-dock\take-lock.ps1') -What "lab 051: security fixes check on disposable $Name" -Me $Me -MaxMinutes 240
if ($LASTEXITCODE -ne 0) { throw 'no lock' }
$Results = [ordered]@{}
$s = $null
try {
    New-GpuVM -Name $Name -Template $Template -Disposable -Use agent -Override @{ vm = @{ memoryGB = 4; cpu = @{ count = 4 } } } -Confirm:$false | Out-Null
    $v0 = (Wait-Agent).version
    Step "clone ready, installed agent $v0"
    $gc = & (Get-Module GpuVM) { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $Name
    $s = New-PSSession -VMName $Name -Credential $gc
    $dist = (Get-Content (Join-Path $repo 'guest\agent\dist\VERSION')).Trim()

    # 1. planted junction
    As-Agent 'move C:\Users\agent\Desktop\Outbox C:\Users\agent\Desktop\Outbox.real & mklink /J C:\Users\agent\Desktop\Outbox "C:\Program Files\GpuVM Agent"'
    $before = Invoke-Command -Session $s { [ordered]@{ outboxIsLink = [bool]((Get-Item C:\Users\agent\Desktop\Outbox -Force).Attributes -band [IO.FileAttributes]::ReparsePoint); programFilesOwner = (Get-Acl 'C:\Program Files\GpuVM Agent').Owner } }
    Copy-Dist
    $r = Invoke-Command -Session $s -FilePath $install -ArgumentList $staging
    $after = Invoke-Command -Session $s { [ordered]@{ outboxIsLink = [bool]((Get-Item C:\Users\agent\Desktop\Outbox -Force).Attributes -band [IO.FileAttributes]::ReparsePoint); outboxOwner = (Get-Acl C:\Users\agent\Desktop\Outbox).Owner; programFilesOwner = (Get-Acl 'C:\Program Files\GpuVM Agent').Owner; desktopIniInProgramFiles = (Test-Path 'C:\Program Files\GpuVM Agent\desktop.ini') } }
    $Results.junction = [ordered]@{ before = $before; install = [ordered]@{ version = $r.version; fastPath = $r.fastPath; notes = $r.notes }; after = $after }
    Step "1 junction: $($Results.junction | ConvertTo-Json -Compress -Depth 5)"

    # 2. new agent, displays, Notepad
    $info = Wait-Agent $dist
    Call 'exec.run' @{ file = 'cmd.exe'; args = @('/c', 'start', '', 'notepad.exe'); timeoutMs = 5000 } 20 | Out-Null
    Start-Sleep -Seconds 2
    $tree = (Call 'ui.tree' @{ interactiveOnly = $false; maxNodes = 3 }).result
    $shot = Call 'screen.capture' @{ format = 'png'; maxW = 3840; maxH = 2160 }
    if ($shot.ok) { Copy-Item $shot.blobPath (Join-Path $outDir 'notepad.png') }
    $b = $tree.nodes[0].bbox
    $displayDb = Invoke-Command -Session $s { (Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration' -ErrorAction SilentlyContinue | Measure-Object).Count }
    $Results.displays = [ordered]@{ version = $info.version; displays = $info.displays; screen = $info.screen; notepad = $tree.window; bbox = $b
        inside = [bool]($b -and $b[0] -ge 0 -and ($b[0] + $b[2]) -le $info.screen.w -and ($b[1] + $b[3]) -le $info.screen.h); displayConfigEntries = $displayDb }
    Step "2 displays: $($Results.displays | ConvertTo-Json -Compress -Depth 5)"
    Call 'exec.run' @{ file = 'cmd.exe'; args = @('/c', 'taskkill', '/im', 'notepad.exe', '/f'); timeoutMs = 5000 } 20 | Out-Null

    # 3. osk.exe (UIAccess)
    Call 'exec.run' @{ file = 'cmd.exe'; args = @('/c', 'start', '', 'osk.exe'); timeoutMs = 5000 } 20 | Out-Null
    Start-Sleep -Seconds 3
    Copy-Item (Join-Path $PSScriptRoot 'harness\target\release\harness.exe') -Destination 'C:\Users\Public\lab051-harness.exe' -ToSession $s -Force
    As-Agent 'C:\Users\Public\lab051-harness.exe guest-window-rect OSKMainClass'
    $rect = Invoke-Command -Session $s { Get-Content C:\Users\Public\lab051-rect.json -Raw -ErrorAction SilentlyContinue } | ConvertFrom-Json
    $osk = [ordered]@{ rect = $rect.rect; found = $rect.found }
    if ($rect.found) {
        $cx = ($rect.rect[0] + $rect.rect[2]) / 2; $cy = ($rect.rect[1] + $rect.rect[3]) / 2
        $osk.clickOnOsk = (Call 'input.act' @{ actions = @(@{ type = 'click'; x = $cx; y = $cy }) }).error
    }
    $shot = Call 'screen.capture' @{ format = 'png'; maxW = 3840; maxH = 2160 }
    if ($shot.ok) { Copy-Item $shot.blobPath (Join-Path $outDir 'osk.png') }
    $osk.state = (Call 'screen.state').result.foreground
    $Results.osk = $osk
    Step "3 osk: $($osk | ConvertTo-Json -Compress -Depth 5)"
    Call 'exec.run' @{ file = 'cmd.exe'; args = @('/c', 'taskkill', '/im', 'osk.exe', '/f'); timeoutMs = 5000 } 20 | Out-Null

    # 4. template preparation, then the copy's fast path
    $prep = Invoke-Command -Session $s ([scriptblock]::Create("& { $(Get-Content $install -Raw) } -PrepareTemplate"))
    $left = Invoke-Command -Session $s {
        Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class L51 { [StructLayout(LayoutKind.Sequential)] struct U { public ushort L; public ushort M; public IntPtr B; } [StructLayout(LayoutKind.Sequential)] struct A { public int Len; public IntPtr R; public IntPtr N; public uint At; public IntPtr S; public IntPtr Q; } [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr s, ref A a, uint acc, out IntPtr h); [DllImport("advapi32.dll")] static extern uint LsaRetrievePrivateData(IntPtr h, ref U k, out IntPtr d); [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr p); [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr h); public static bool Has(string key) { var a = new A(); a.Len = Marshal.SizeOf(a); IntPtr h; LsaOpenPolicy(IntPtr.Zero, ref a, 4, out h); IntPtr m = Marshal.StringToHGlobalUni(key); var k = new U(); k.L = (ushort)(key.Length*2); k.M = (ushort)(key.Length*2+2); k.B = m; IntPtr d; uint r = LsaRetrievePrivateData(h, ref k, out d); bool has = false; if (r == 0) { has = Marshal.ReadInt16(d) > 0; LsaFreeMemory(d); } Marshal.FreeHGlobal(m); LsaClose(h); return has; } }' -ErrorAction SilentlyContinue
        $b = Get-Item 'HKLM:\SOFTWARE\GpuVM\Agent\Backup' -ErrorAction SilentlyContinue
        [ordered]@{
            lsaDefaultPassword = [L51]::Has('DefaultPassword'); lsaPrevious = [L51]::Has('GpuVMAgent_PreviousDefaultPassword'); lsaPrevPlain = [L51]::Has('GpuVMAgent_PreviousPlainDefaultPassword')
            backupEntries = @(if ($b) { $b.Property }) -join '; '
            autoAdminLogon = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').AutoAdminLogon
            secret = Test-Path C:\ProgramData\GpuVM\Agent\secret
        }
    }
    $Results.template = [ordered]@{ prepare = $prep; left = $left }
    Step "4 template: $($Results.template | ConvertTo-Json -Compress -Depth 5)"
    Copy-Dist
    $k = [byte[]]::new(32); [Security.Cryptography.RandomNumberGenerator]::Fill($k)
    $fast = Invoke-Command -Session $s -FilePath $install -ArgumentList $staging, $k
    Remove-PSSession $s; $s = $null
    Invoke-Command -VMName $Name -Credential $gc { Restart-Computer -Force }
    $sw = [Diagnostics.Stopwatch]::StartNew(); $u = $null
    do { Start-Sleep -Seconds 3; $u = try { Invoke-Command -VMName $Name -Credential $gc -ErrorAction Stop { (Get-CimInstance Win32_ComputerSystem).UserName } } catch { $null } } until ($u -like '*\agent' -or $sw.Elapsed.TotalMinutes -gt 5)
    $Results.copy = [ordered]@{ fastPath = $fast.fastPath; rebootNeeded = $fast.rebootNeeded; signedInAfterRestart = $u; seconds = [int]$sw.Elapsed.TotalSeconds }
    Step "4 copy: $($Results.copy | ConvertTo-Json -Compress)"
}
catch { Step "FAILED: $($_.Exception.Message)"; throw }
finally {
    if ($s) { Remove-PSSession $s }
    $Results | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $outDir 'results.json')
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 5
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Step "results: $outDir; VM left: $([bool](Get-VM -Name $Name -ErrorAction SilentlyContinue)); lock released"
}
