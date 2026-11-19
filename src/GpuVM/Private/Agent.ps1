# The agent broker lives in the GpuVM service (app/host/src/agent.rs). The module talks to it over an
# administrators-only pipe with the same lines as the service pipe: {"id","cmd","args"} -> {"type":"result",...}.
# The app and the MCP server send the same commands to the service pipe, where the service answers them itself.

$script:AgentPipeName = 'gpuvm-agent'
$script:AgentPipe = $null
$script:AgentPipeIO = $null
# Mixed into the DPAPI encryption of each VM's secret; the service uses the same (agent.rs SECRET_ENTROPY).
$script:AgentSecretEntropy = [Text.Encoding]::ASCII.GetBytes('GpuVM agent secret v1')
# Inside the guest (protocol.md).
$script:GuestAgentDir = 'C:\ProgramData\GpuVM\Agent'

function Get-GpuVMAgentRoot {
    Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'GpuVM\agents'
}

# One persistent connection per PowerShell session (requests are answered in order).
function Invoke-AgentBroker {
    param(
        [Parameter(Mandatory)][string]$Command,
        [System.Collections.IDictionary]$Arguments = @{}
    )
    if (-not $script:AgentPipe -or -not $script:AgentPipe.IsConnected) {
        $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $script:AgentPipeName, [IO.Pipes.PipeDirection]::InOut)
        try { $pipe.Connect(3000) }
        catch {
            $pipe.Dispose()
            throw 'The GpuVM service isn''t running (or this PowerShell isn''t elevated): start GpuVM and try again.'
        }
        $script:AgentPipe = $pipe
        $script:AgentPipeIO = @{
            Reader = [IO.StreamReader]::new($pipe, [Text.UTF8Encoding]::new($false), $false, 65536, $true)
            Writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 65536, $true)
        }
    }
    $request = [ordered]@{ id = [guid]::NewGuid().ToString('n'); cmd = $Command; args = $Arguments }
    $line = $request | ConvertTo-Json -Depth 20 -Compress
    # Write the newline explicitly: WriteLine would end with CR+LF.
    $script:AgentPipeIO.Writer.Write($line + "`n")
    $script:AgentPipeIO.Writer.Flush()
    $reply = $script:AgentPipeIO.Reader.ReadLine()
    if ($null -eq $reply) {
        $script:AgentPipe.Dispose(); $script:AgentPipe = $null
        throw 'The GpuVM service closed the connection.'
    }
    $result = $reply | ConvertFrom-Json -AsHashtable
    if (-not $result['ok']) {
        $exception = [InvalidOperationException]::new([string]$result['error'])
        $exception.Data['code'] = $result['code']
        throw $exception
    }
    # Items one by one (the caller wraps with @() when it wants a list).
    foreach ($item in $result['data']) { $item }
}

# A function's bound parameters as broker arguments: common parameters (-Verbose...) left out, switches as booleans.
function ConvertTo-AgentArguments {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Bound)
    $common = [System.Management.Automation.Cmdlet]::CommonParameters + [System.Management.Automation.Cmdlet]::OptionalCommonParameters
    $result = @{}
    foreach ($key in $Bound.Keys) {
        if ($key -in $common) { continue }
        $value = $Bound[$key]
        $result[$key] = if ($value -is [switch]) { $value.IsPresent } else { $value }
    }
    $result
}

# ProgramData\GpuVM\agents\<vmid>: SYSTEM and Administrators only, nothing inherited (the service trusts what is in it).
function Initialize-AgentFolder {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Path is a link; GpuVM won't use it." }
    & icacls.exe $Path /setowner '*S-1-5-32-544' /Q | Out-Null
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Couldn't restrict the permissions of $Path." }
}

# Hands the VM's secret K to the GpuVM service, which keeps it as SYSTEM (DPAPI machine scope + GpuVM's entropy, a
# file only SYSTEM can open, created that way and renamed over the old one). Done there because an elevated user
# (the app's bridge) can't handle a file it isn't allowed to open; the folder is the VM's registration folder.
function Write-AgentSecret {
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][byte[]]$Secret)
    $text = [Convert]::ToBase64String($Secret)
    try { Invoke-AgentBroker -Command 'Set-GpuVMAgentSecret' -Arguments @{ VmId = (Split-Path $Folder -Leaf); Secret = $text } | Out-Null }
    finally { $text = $null }
}


# The guest agent: guest\agent\install.ps1 and gpuvm-agent.exe (dist\ in an installed GpuVM, target\release\ in a
# developer's copy). The version is what the exe itself says (`gpuvm-agent.exe version`).
function Get-AgentPackage {
    $root = Get-RepoPath 'guest\agent'
    $install = Join-Path $root 'install.ps1'
    # guest\agent\build.ps1 puts what goes into a guest in dist\: gpuvm-agent.exe and VERSION.
    $dist = Join-Path $root 'dist'
    $exe = Join-Path $dist 'gpuvm-agent.exe'
    if (-not (Test-Path -LiteralPath $install) -or -not (Test-Path -LiteralPath $exe)) {
        throw "The guest agent isn't in this GpuVM build ($dist; a developer's copy builds it with guest\agent\build.ps1)."
    }
    $versionFile = Join-Path $dist 'VERSION'
    $version = if (Test-Path -LiteralPath $versionFile) { (Get-Content -Raw -LiteralPath $versionFile).Trim() } else { $null }
    [pscustomobject]@{ Install = $install; Exe = $exe; Version = $version; Hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
        Files = @(Get-ChildItem -LiteralPath $dist -File) }
}

# Deletes the agent's secret from a mounted guest disk (a template or a copy of one): copies never share a secret.
function Remove-GuestAgentSecret {
    param([Parameter(Mandatory)][string]$WindowsRoot)
    # Done on the disk copy, not in the running source VM (install.ps1 -PrepareTemplate would also take the source
    # machine's agent offline). The same as -PrepareTemplate: the secret, the logs and a leftover staging folder.
    $dir = Join-Path $WindowsRoot 'ProgramData\GpuVM\Agent'
    Assert-NoReparsePoint -Root $WindowsRoot -Path (Join-Path $dir 'secret')
    if (-not (Test-Path -LiteralPath $dir)) { return }
    foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$($item.Name) on the disk is a link; nothing is deleted through it." }
        if ($item.Name -eq 'secret' -or $item.Name -like '*.log' -or $item.Name -eq 'staging') {
            # A folder written by the guest: a link anywhere inside it would send the deletion to this PC's files.
            if ($item.PSIsContainer -and @(Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -Attributes ReparsePoint -ErrorAction Stop).Count) {
                throw "$($item.Name) on the disk holds a link; nothing is deleted through it."
            }
            Remove-Item -LiteralPath $item.FullName -Recurse -Force
        }
    }
}

# Called when a VM is deleted or renamed: the service finds agents by these registrations.
function Remove-GpuVMAgentRegistration {
    param([Parameter(Mandatory)][string]$VMId)
    $dir = Join-Path (Get-GpuVMAgentRoot) $VMId.ToLowerInvariant()
    if (-not (Test-Path -LiteralPath $dir)) { return }
    # The secret is SYSTEM-only (lab 054: an administrator's Remove-Item was denied and the deletion reported an
    # error), so the service removes the folder. The machine itself is already gone or uninstalled by then, so a
    # service that can't be reached is a warning: its hourly sweep removes registrations of VMs that don't exist.
    try { Invoke-AgentBroker -Command 'Remove-GpuVMAgentRegistration' -Arguments @{ VmId = $VMId.ToLowerInvariant() } | Out-Null }
    catch { Write-Warning "GpuVM's service couldn't remove the agent registration of $VMId now ($($_.Exception.Message)); it is removed within the hour once the machine no longer exists." }
}

function Update-GpuVMAgentRegistration {
    param([Parameter(Mandatory)][string]$Name)
    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) { return }
    $file = Join-Path (Join-Path (Get-GpuVMAgentRoot) $vm.Id.Guid.ToLowerInvariant()) 'agent.json'
    if (-not (Test-Path -LiteralPath $file)) { return }
    $registration = Read-JsonFile $file
    $state = Get-GpuVMState -Name $Name
    $registration['name'] = $Name
    $registration['folder'] = Split-Path $state['statePath'] -Parent
    Write-JsonFile -Path $file -Data $registration
}

# Ends a PowerShell Direct session (a function so tests can replace it).
function Close-AgentSession {
    param($Session)
    Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
}

# PowerShell Direct calls in one session (functions so tests can replace them; a PSSession can't be faked).
function Invoke-InAgentSession {
    param($Session, [scriptblock]$ScriptBlock, [object[]]$ArgumentList = @())
    Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
}

function Copy-ToAgentSession {
    param($Session, [string]$Path, [string]$Destination)
    Copy-Item -LiteralPath $Path -ToSession $Session -Destination $Destination -ErrorAction Stop
}

# Whether an agent machine needs Install-GpuVMAgent: its install is pending, or the agent it has is older than the one
# this build carries (a copy of a template made with an earlier release, lab 054: 0.3.2 in copies of agent-tpl).
function Test-GpuVMAgentStale {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State, [string]$BundledVersion)
    if ([string]$State['use'] -ne 'agent') { return $false }
    $agent = $State['agent']
    if (-not ($agent -is [System.Collections.IDictionary])) { return $true }
    if ($agent['pending']) { return $true }
    if (-not $BundledVersion) { return $false }
    $have = [string]$agent['version']
    if (-not $have) { return $true }
    $parse = { param($v) $m = [regex]::Match($v, '^\d+(\.\d+){1,3}'); if ($m.Success) { [version]$m.Value } }
    $a = & $parse $have
    $b = & $parse $BundledVersion
    if ($a -and $b) { return $a -lt $b }
    $have -ne $BundledVersion
}

# Connect-GpuVM on a running agent machine: installs or refreshes the agent when it is pending or older than this
# build's (~9 s), so templates don't go stale with every release. Never stops the open: a failure is a warning.
# Returns $true when Windows restarted for it, once the new boot is under way (the caller then waits for Windows,
# the sign-in and the session again).
function Update-GpuVMAgentIfStale {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][pscredential]$Credential, [int]$RestartTimeoutSec = 600)
    $state = Get-GpuVMState -Name $Name
    if ([string]$state['use'] -ne 'agent') { return $false }
    $package = try { Get-AgentPackage } catch { $null }
    if (-not $package) { return $false }
    if (-not (Test-GpuVMAgentStale -State $state -BundledVersion $package.Version)) { return $false }
    $user = if ($state['agent'] -is [System.Collections.IDictionary] -and $state['agent']['signInAs']) { [string]$state['agent']['signInAs'] } else { 'agent' }
    $bootBefore = try { Get-GuestBootTime -Name $Name -Credential $Credential } catch { '' }
    Write-Step 'Updating GpuVM''s agent in the machine'
    try { $installed = Install-GpuVMAgent -Name $Name -User $user }
    catch { Write-Warning "GpuVM's agent couldn't be updated in '$Name': $($_.Exception.Message)"; return $false }
    if (-not ($installed -and $installed['restarted'])) { return $false }
    # Install-GpuVMAgent asks Windows to restart and returns at once: wait until the old Windows is gone, so the next
    # checks don't talk to the one still shutting down.
    $deadline = (Get-Date).AddSeconds($RestartTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $now = try { Get-GuestBootTime -Name $Name -Credential $Credential } catch { $null }
        if ($now -and $now -ne $bootBefore) { break }
        Start-Sleep -Seconds 2
    }
    $true
}

# Turns a running machine off (Windows shuts down cleanly; turned off after -ShutdownTimeoutSec) and on again. Not a
# restart: on some copies Windows gives the session no display path at all, a state that lives in the running VM's
# GPU partition and only a power cycle clears (agent-guest lab 051, 2026-11-19: 12 of 12 copies with a display after
# it, against 2 of 12 without before). A disposable machine is marked meanwhile so the sweep never deletes it while it
# is off. Returns when Start-VM did.
function Restart-GpuVMCold {
    param([Parameter(Mandatory)][string]$Name, [int]$ShutdownTimeoutSec = 180)
    $state = Get-GpuVMState -Name $Name
    $disposable = $state['disposable'] -is [System.Collections.IDictionary]
    if ($disposable) {
        $state['disposable']['cyclingUntil'] = (Get-Date).AddMinutes(10).ToUniversalTime().ToString('o')
        Save-GpuVMState $state
    }
    try {
        Write-Step 'Turning the machine off and on again'
        $job = Stop-VM -Name $Name -Force -AsJob
        $deadline = (Get-Date).AddSeconds($ShutdownTimeoutSec)
        while ((Get-VM -Name $Name).State -ne 'Off' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
        if ((Get-VM -Name $Name).State -ne 'Off') { Stop-VM -Name $Name -TurnOff -Force }
        $job | Remove-Job -Force -ErrorAction SilentlyContinue
        # As any start: the isolation follows the host's current address on the switch.
        Update-GpuVMNetworkIsolation -Name $Name
        Start-VM -Name $Name
    }
    finally {
        if ($disposable) {
            $state = Get-GpuVMState -Name $Name
            if ($state['disposable'] -is [System.Collections.IDictionary] -and $state['disposable'].Contains('cyclingUntil')) {
                $state['disposable'].Remove('cyclingUntil')
                Save-GpuVMState $state
            }
        }
    }
}

# An agent machine keeps the Hyper-V display on: until a viewer connects, the virtual display has no monitor plugged
# in, and without the Hyper-V one the console session has no display at all (no screenshots, no input; agent-guest
# 2026-11-19 on copies of a template whose source had it disabled). The agent (0.4.x) turns that display's desktop
# off itself once the virtual one is active, and Sunshine captures the virtual display by name.
# Returns 'enabled' (it was off), 'ok' or 'not-found'.
function Enable-GuestHyperVVideo {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][pscredential]$Credential)
    $r = Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock {
        $devices = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object FriendlyName -like '*Hyper-V*')
        if (-not $devices) { return 'not-found' }
        $off = @($devices | Where-Object Status -ne 'OK')
        if (-not $off) { return 'ok' }
        $off | Enable-PnpDevice -Confirm:$false -ErrorAction Stop
        'enabled'
    }
    [string](@($r)[-1])
}

# The agent's removal inside a running machine (install.ps1 -Uninstall -RemoveUser): its last result.
function Invoke-GuestAgentRemoval {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][pscredential]$Credential)
    # The script's text runs with named arguments (switches never bind by position; guests are Restricted).
    $code = Get-Content -Raw -LiteralPath (Get-RepoPath 'guest\agent\install.ps1')
    Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ArgumentList $code -ScriptBlock {
        param($code) & ([scriptblock]::Create($code)) -Uninstall -RemoveUser
    } | Select-Object -Last 1
}

# After the restart the removal asked for: waits for the new Windows (BootBefore = the boot it replaces; empty when
# the machine was opened later) and runs the removal again, which now deletes the `agent` user and its profile.
# $true when nothing is left to do.
function Complete-GuestAgentRemoval {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][pscredential]$Credential, [string]$BootBefore = '', [int]$TimeoutSec = 600)
    if ($BootBefore) {
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            $now = try { Get-GuestBootTime -Name $Name -Credential $Credential } catch { $null }
            if ($now -and $now -ne $BootBefore) { break }
            Start-Sleep -Seconds 2
        }
        Wait-GuestReady -Name $Name -Credential $Credential -BootMessage 'Waiting for Windows'
    }
    $r = try { Invoke-GuestAgentRemoval -Name $Name -Credential $Credential } catch { Write-Warning "Couldn't finish removing the agent inside '$Name': $($_.Exception.Message)"; return $false }
    # Still signed in as `agent` (the person's sign-in didn't take): left for the next open.
    -not ($r -and $r.PSObject.Properties['rebootNeeded'] -and $r.rebootNeeded -and @($r.notes) -match 'signed in')
}

# Once a stream is up on an agent machine: the agent repaints the whole desktop (screen.refresh, agent 0.3.8), so
# Sunshine's ddx capture gets a fresh frame of a still desktop instead of staying black (1 connect in 3, lab 054).
# Best effort and quiet: an older agent (bad_request), no agent connected or nobody signed in changes nothing.
function Invoke-AgentScreenRefresh {
    param([Parameter(Mandatory)][string]$Name)
    $state = try { Get-GpuVMState -Name $Name } catch { $null }
    if (-not $state -or [string]$state['use'] -ne 'agent') { return $false }
    try { Invoke-GpuVMAgent -Name $Name -Method screen.refresh -TimeoutSec 5 -ErrorAction Stop | Out-Null; $true }
    catch { $false }
}

# New-GpuVM / Import-GpuVM -Use agent: remembers who signs in, waits for Windows when the machine runs, then sets the
# use (which installs the agent). Never fails the creation: a problem leaves the agent pending, with a warning.
function Initialize-GpuVMAgentUse {
    param([Parameter(Mandatory)][string]$Name, [ValidateSet('agent', 'own')][string]$User = 'agent')
    $state = Get-GpuVMState -Name $Name
    $state['agent'] = [ordered]@{ pending = $true; signInAs = $User }
    $state['use'] = 'agent'
    Save-GpuVMState $state
    try {
        if ((Get-VM -Name $Name).State -eq 'Running') {
            $credential = Get-GpuVMGuestCredential -State $state
            if ($credential) { Wait-GuestReady -Name $Name -Credential $credential | Out-Null }
        }
        Set-GpuVMUse -Name $Name -Use agent | Out-Null
    }
    catch { Write-Warning "The machine is ready, but GpuVM's agent isn't installed yet: $($_.Exception.Message)" }
}
