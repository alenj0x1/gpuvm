$script:AgentPipeName = 'gpuvm-agent'
$script:AgentPipe = $null
$script:AgentPipeIO = $null
# Mixed into the DPAPI encryption of each VM's secret; the service uses the same (agent.rs SECRET_ENTROPY).
$script:AgentSecretEntropy = [Text.Encoding]::ASCII.GetBytes('GpuVM agent secret v1')
$script:GuestAgentDir = 'C:\ProgramData\GpuVM\Agent'

function Get-GpuVMAgentRoot {
    Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'GpuVM\agents'
}

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
    foreach ($item in $result['data']) { $item }
}

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

# SYSTEM and Administrators only, nothing inherited: the service trusts what is in it.
function Initialize-AgentFolder {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Path is a link; GpuVM won't use it." }
    & icacls.exe $Path /setowner '*S-1-5-32-544' /Q | Out-Null
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Couldn't restrict the permissions of $Path." }
}

# Handed to the service: the secret file is SYSTEM-only, which an elevated user can't open.
function Write-AgentSecret {
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][byte[]]$Secret)
    $text = [Convert]::ToBase64String($Secret)
    try { Invoke-AgentBroker -Command 'Set-GpuVMAgentSecret' -Arguments @{ VmId = (Split-Path $Folder -Leaf); Secret = $text } | Out-Null }
    finally { $text = $null }
}


function Get-AgentPackage {
    $root = Get-RepoPath 'guest\agent'
    $install = Join-Path $root 'install.ps1'
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

function Remove-GuestAgentSecret {
    param([Parameter(Mandatory)][string]$WindowsRoot)
    # Done on the disk copy: install.ps1 -PrepareTemplate would take the source machine's agent offline.
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

function Remove-GpuVMAgentRegistration {
    param([Parameter(Mandatory)][string]$VMId)
    $dir = Join-Path (Get-GpuVMAgentRoot) $VMId.ToLowerInvariant()
    if (-not (Test-Path -LiteralPath $dir)) { return }
    # The secret is SYSTEM-only, so the service removes the folder; its hourly sweep covers an unreachable service.
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

# A function so tests can replace it.
function Close-AgentSession {
    param($Session)
    Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
}

# Functions so tests can replace them: a PSSession can't be faked.
function Invoke-InAgentSession {
    param($Session, [scriptblock]$ScriptBlock, [object[]]$ArgumentList = @())
    Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
}

function Copy-ToAgentSession {
    param($Session, [string]$Path, [string]$Destination)
    Copy-Item -LiteralPath $Path -ToSession $Session -Destination $Destination -ErrorAction Stop
}

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
    # Install-GpuVMAgent requests a restart and returns at once: wait until the old Windows is gone.
    $deadline = (Get-Date).AddSeconds($RestartTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $now = try { Get-GuestBootTime -Name $Name -Credential $Credential } catch { $null }
        if ($now -and $now -ne $bootBefore) { break }
        Start-Sleep -Seconds 2
    }
    $true
}

# A power cycle, not a restart: some copies get no display path, a GPU partition state only a power cycle clears.
function Restart-GpuVMCold {
    param([Parameter(Mandatory)][string]$Name, [int]$ShutdownTimeoutSec = 90, [int]$TurnOffTimeoutSec = 30)
    $state = Get-GpuVMState -Name $Name
    $disposable = $state['disposable'] -is [System.Collections.IDictionary]
    if ($disposable) {
        $state['disposable']['cyclingUntil'] = (Get-Date).AddMinutes(10).ToUniversalTime().ToString('o')
        Save-GpuVMState $state
    }
    try {
        Write-Step 'Turning the machine off and on again'
        # Off and on as one transition: no other GPU machine changes power in between (GpuPower.ps1).
        Invoke-GpuPowerTransition -Name $Name -UntilUp -Do {
            Stop-GpuVMBounded -Name $Name -ShutdownTimeoutSec $ShutdownTimeoutSec -TurnOffTimeoutSec $TurnOffTimeoutSec
            Update-GpuVMNetworkIsolation -Name $Name
            # The module's Start-VM: it takes the same mutex again (a mutex is reentrant on its own thread).
            Start-VM -Name $Name
        }
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

function Stop-GpuVMBounded {
    param([Parameter(Mandatory)][string]$Name, [int]$ShutdownTimeoutSec = 90, [int]$TurnOffTimeoutSec = 30)
    $off = { param($s) $deadline = (Get-Date).AddSeconds($s); while ((Get-VM -Name $Name).State -ne 'Off' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }; (Get-VM -Name $Name).State -eq 'Off' }
    if ((Get-VM -Name $Name).State -eq 'Off') { return }
    $jobs = @(Stop-VM -Name $Name -Force -AsJob)
    try {
        if (& $off $ShutdownTimeoutSec) { return }
        Write-Warning "Windows in '$Name' didn't shut down in $ShutdownTimeoutSec s; it is turned off."
        Write-PowerLog "$Name didn't shut down in $ShutdownTimeoutSec s; turned off"
        $jobs += Stop-VM -Name $Name -TurnOff -Force -AsJob
        if (& $off $TurnOffTimeoutSec) { return }
        # Hyper-V won't turn off a machine it sees as shutting down: its worker process is ended (only that VM's).
        $id = (Get-VM -Name $Name).Id.Guid
        $worker = @(Get-CimInstance Win32_Process -Filter "Name='vmwp.exe'" | Where-Object { $_.CommandLine -match [regex]::Escape($id) })
        Write-Warning "'$Name' didn't turn off; its Hyper-V worker process is ended."
        Write-PowerLog "$Name didn't shut down nor turn off; its worker process ($(@($worker.ProcessId) -join ', ')) was ended"
        $worker | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        if (& $off $TurnOffTimeoutSec) { return }
        throw "'$Name' couldn't be turned off (it is $((Get-VM -Name $Name).State))."
    }
    finally {
        # Only finished jobs are removed: disposing a Hyper-V job before it completes ends the PowerShell process.
        $jobs | Wait-Job -Timeout 15 -ErrorAction SilentlyContinue | Out-Null
        $jobs | Where-Object { $_.State -in 'Completed', 'Failed', 'Stopped' } | Remove-Job -Force -ErrorAction SilentlyContinue
    }
}

# Without the Hyper-V display, an agent machine's console session has no display until a viewer connects.
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

function Install-GuestSunshineCapture {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][pscredential]$Credential)
    $files = [ordered]@{}
    $hashes = [ordered]@{}
    foreach ($file in Get-SunshineForkFiles) { $files[$file.Key] = $file.Path; $hashes[$file.Key] = $file.Hash }
    $session = New-PSSession -VMName $Name -Credential $Credential -ErrorAction Stop
    try {
        $differ = @(Invoke-InAgentSession $session -ArgumentList $hashes -ScriptBlock {
                param($hashes)
                $dir = 'C:\Program Files\Sunshine'
                foreach ($key in $hashes.Keys) {
                    $path = Join-Path $dir $key
                    if (-not (Test-Path -LiteralPath $path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $hashes[$key]) { $key }
                }
            })
        $result = 'unchanged'
        try {
            if ($differ.Count) {
                Write-Step 'Installing GpuVM''s Sunshine in the machine'
                # The fork only goes over the Sunshine version it was built from (or an earlier fork): the files around the exe would differ.
                $pinned = ([string](Get-ComponentManifest)['sunshine']['version']).TrimStart('v')
                Invoke-InAgentSession $session -ArgumentList $pinned, ([string]$hashes['sunshine.exe']) -ScriptBlock {
                    param($pinned, $forkHash)
                    $dir = 'C:\Program Files\Sunshine'
                    $exe = "$dir\sunshine.exe"
                    if (-not (Test-Path -LiteralPath $exe)) { throw 'Sunshine isn''t installed in the VM.' }
                    $version = [string](Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
                    $isFork = $version -like '0.0.0-*' -or (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -eq $forkHash
                    if (-not $isFork -and $version -and $version -notlike "$pinned*") {
                        throw "The VM has Sunshine $version and GpuVM's is built on $pinned; update the VM's Sunshine first (Update-GpuVMComponent)."
                    }
                    Get-Service | Where-Object { $_.Name -like '*sunshine*' } | Stop-Service -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                    Get-Process sunshine, sunshine_wgc_capture -ErrorAction SilentlyContinue | Stop-Process -Force
                    New-Item -ItemType Directory -Force "$dir\tools" | Out-Null
                }
                foreach ($key in $differ) { Copy-ToAgentSession $session -Path $files[$key] -Destination "C:\Program Files\Sunshine\$key" }
                $result = 'installed'
            }
            Invoke-InAgentSession $session -ScriptBlock {
                $config = 'C:\Program Files\Sunshine\config'
                & icacls.exe $config /inheritance:d /Q | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Couldn't change the permissions of $config." }
                # Users and sandboxed Store apps lose read access: the signed-in user must never read Sunshine's keys.
                & icacls.exe $config /remove:g '*S-1-5-32-545' '*S-1-15-2-1' '*S-1-15-2-2' /T /Q | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Couldn't take Users' access off $config." }
            }
        }
        finally {
            Invoke-InAgentSession $session -ScriptBlock {
                Get-Service | Where-Object { $_.Name -like '*sunshine*' } | Start-Service -ErrorAction SilentlyContinue
            }
        }
        $state = Get-GpuVMState -Name $Name
        $state['sunshineFork'] = Get-SunshineForkStamp
        Save-GpuVMState $state
        $result
    }
    finally { Close-AgentSession $session }
}

function Get-SunshineForkStamp { (@(Get-SunshineForkFiles | ForEach-Object { "$($_.Key)=$($_.Hash)" }) + 'setup=2') -join ';' }

function Sync-GuestSunshineFork {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][pscredential]$Credential)
    $state = Get-GpuVMState -Name $Name
    if ([string]$state['sunshineFork'] -eq (Get-SunshineForkStamp)) { return 'current' }
    Install-GuestSunshineCapture -Name $Name -Credential $Credential
}

function Initialize-GuestStreamingForAgent {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][pscredential]$Credential)
    $state = Get-GpuVMState -Name $Name
    if (-not $state['streaming'] -or -not $state['config']['streaming']['virtualDisplay']) { return }
    $helper = try { Install-GuestSunshineCapture -Name $Name -Credential $Credential }
    catch { Write-Warning "Couldn't install GpuVM's Sunshine capture helper: $($_.Exception.Message)"; 'failed' }
    if ($state['streamingFromTemplate'] -and $helper -eq 'unchanged') {
        $changed = Set-GuestCaptureMode -Name $Name -Credential $Credential
        $state = Get-GpuVMState -Name $Name
        $state.Remove('streamingFromTemplate')
        Save-GpuVMState $state
        if (-not $changed) { return }
    }
    $address = Get-GpuVMAddress -Name $Name -TimeoutSec 120
    $web = Get-SunshineCredential -State $state
    Wait-SunshineReady -Address $address -Credential $web -TimeoutSec 180 -Message 'Waiting for Sunshine'
    $null = Set-GuestCaptureMode -Name $Name -Credential $Credential
    Wait-SunshineReady -Address $address -Credential $web -TimeoutSec 120 -Message 'Sunshine is restarting with the new settings'
    Set-SunshineVirtualDisplay -Address $address -Credential $web -OnlyDisplay -Name $Name -GuestCredential $Credential
}

function Get-GpuVMStreamMode {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State, [string]$Monitor)
    $client = $State['config']['streaming']['client']
    $chosen = if ($Monitor) { $Monitor } elseif ($client -and $client.Contains('monitor')) { [string]$client['monitor'] } else { '' }
    $fps = [int]$client['fps']
    if ($fps -le 0) {
        $target = try { Resolve-HostMonitor -Monitor $chosen } catch { $null }
        $fps = Resolve-GpuVMStreamFps 0 -Hz $(if ($target) { $target['hz'] } else { 0 })
    }
    "$($client['resolution'])@$(Resolve-GpuVMStreamFps $fps)"
}

function Sync-GuestAgentDisplayMode {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][pscredential]$Credential, [Parameter(Mandatory)][string]$Mode)
    # The agent's own limits: 1280-7680 x 720-4320, 24-500 Hz.
    if ($Mode -notmatch '^(\d{4})x(\d{3,4})@(\d{2,3})$' -or [int]$Matches[1] -lt 1280 -or [int]$Matches[1] -gt 7680 -or
        [int]$Matches[2] -lt 720 -or [int]$Matches[2] -gt 4320 -or [int]$Matches[3] -lt 24 -or [int]$Matches[3] -gt 500) { return $false }
    $state = Get-GpuVMState -Name $Name
    if ([string]$state['agentDisplayMode'] -eq $Mode) { return $false }
    Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ArgumentList $Mode -ScriptBlock {
        param($mode)
        $key = 'HKLM:\SOFTWARE\GpuVM\Agent'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        Set-ItemProperty -Path $key -Name StreamMode -Value $mode -Type String
    }
    $state = Get-GpuVMState -Name $Name
    $state['agentDisplayMode'] = $Mode
    Save-GpuVMState $state
    $true
}

function Invoke-GuestAgentRemoval {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][pscredential]$Credential)
    # Script text with named arguments: switches never bind by position and guests are Restricted.
    $code = Get-Content -Raw -LiteralPath (Get-RepoPath 'guest\agent\install.ps1')
    Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ArgumentList $code -ScriptBlock {
        param($code) & ([scriptblock]::Create($code)) -Uninstall -RemoveUser
    } | Select-Object -Last 1
}

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
    -not ($r -and $r.PSObject.Properties['rebootNeeded'] -and $r.rebootNeeded -and @($r.notes) -match 'signed in')
}

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
