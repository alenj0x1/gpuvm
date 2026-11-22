function Install-GpuVMAgent {
    <#
    .SYNOPSIS
    Installs (or reinstalls) GpuVM's agent inside a running VM, with a new per-VM secret and a new password for the
    standard Windows user `agent` it works as. Also the fast path for a copy of a template that already has the agent.

    .DESCRIPTION
    The secret is kept on this PC with DPAPI, readable by SYSTEM only (the GpuVM service). Over PowerShell Direct,
    with the machine's saved administrator account, the agent is installed or updated, the secret is written in the
    guest for SYSTEM and Administrators only, and `agent` gets a new password (kept with DPAPI in gpuvm.json). When
    the installer asks for it, the machine is shut down and started again (a power cycle, not a restart).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        # Who Windows signs in as: the agent's own standard user (default), or the person's user as configured before.
        [ValidateSet('agent', 'own')][string]$User = 'agent'
    )
    # Any failure stops the install: it never reports success with a step left undone.
    $ErrorActionPreference = 'Stop'
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    $vm = Get-VM -Name $Name -ErrorAction Stop
    if ($vm.State -ne 'Running') { throw "Start '$Name' first: the agent is installed into the running machine." }
    $credential = Get-GpuVMGuestCredential -State $state
    Assert-AgentSwitch -Name $Name
    if (-not $credential) { throw "GpuVM doesn't know the account of '$Name'. Save it first (Set-GpuVMGuestCredential)." }
    $package = Get-AgentPackage
    $vmId = $vm.Id.Guid.ToLowerInvariant()
    $folder = Join-Path (Get-GpuVMAgentRoot) $vmId
    Initialize-AgentFolder -Path (Get-GpuVMAgentRoot)
    Initialize-AgentFolder -Path $folder
    $timing = [ordered]@{}
    $sw = [Diagnostics.Stopwatch]::StartNew()

    # The first-time setup runs at the first sign-in of the machine's own account: switching to `agent` first would skip it.
    Wait-GuestReady -Name $Name -Credential $credential
    # Without a viewer the console's only display is the Hyper-V one: it stays on for the agent.
    try { $null = Enable-GuestHyperVVideo -Name $Name -Credential $credential }
    catch { Write-Warning "Couldn't turn the machine's Hyper-V display on: $($_.Exception.Message)" }
    $timing['firstSetup'] = $sw.ElapsedMilliseconds
    $signInAs = if ($User -eq 'own') { 'previous' } else { 'agent' }
    $secret = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($secret)
    $session = New-PSSession -VMName $Name -Credential $credential -ErrorAction Stop
    try {
        $timing['session'] = $sw.ElapsedMilliseconds
        $setup = Invoke-InAgentSession $session -ArgumentList $package.Hash -ScriptBlock {
            param($hash)
            $installed = 'C:\Program Files\GpuVM Agent\gpuvm-agent.exe'
            $same = (Test-Path -LiteralPath $installed) -and (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash -eq $hash
            $dir = Join-Path $env:SystemRoot "Temp\GpuVMAgentSetup-$([guid]::NewGuid().ToString('n'))"
            New-Item -ItemType Directory -Path $dir | Out-Null
            & icacls.exe $dir /setowner '*S-1-5-32-544' /Q | Out-Null
            & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /Q | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Couldn't restrict $dir." }
            [pscustomobject]@{ Dir = $dir; Same = $same; Installed = $installed }
        }
        try {
            if ($setup.Same) {
                Invoke-InAgentSession $session -ArgumentList $setup.Installed, $setup.Dir, ([string]$package.Version) -ScriptBlock {
                    param($from, $dir, $version)
                    Copy-Item -LiteralPath $from -Destination $dir
                    if ($version) { [IO.File]::WriteAllText((Join-Path $dir 'VERSION'), $version) }
                }
            }
            else {
                Write-Step 'Copying the agent into the machine'
                foreach ($file in $package.Files) {
                    Copy-ToAgentSession $session -Path $file.FullName -Destination (Join-Path $setup.Dir $file.Name)
                }
            }
            $timing['copy'] = $sw.ElapsedMilliseconds
            Write-Step 'Installing the agent and its user'
            $code = Get-Content -Raw -LiteralPath $package.Install
            $output = @(Invoke-InAgentSession $session -ArgumentList $code, $setup.Dir, $secret, $signInAs -ScriptBlock {
                param($code, $dir, $secret, $signInAs) & ([scriptblock]::Create($code)) -Staging $dir -Secret $secret -SignInAs $signInAs
            })
            $timing['install'] = $sw.ElapsedMilliseconds
        }
        finally {
            Invoke-InAgentSession $session -ArgumentList $setup.Dir -ScriptBlock { param($dir) Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $winget = try { Install-GuestWinget -Session $session }
        catch { Write-Warning "winget couldn't be installed in '$Name': $($_.Exception.Message)"; 'failed' }
        $timing['winget'] = $sw.ElapsedMilliseconds
    }
    finally { Close-AgentSession $session }
    $result = $output | Where-Object { $_ -and $_.PSObject.Properties['password'] } | Select-Object -Last 1
    if (-not $result -or -not $result.password) { throw 'The agent''s installer in the machine didn''t return the agent user''s password.' }
    # The host keeps the new secret only once the guest has it, so a failed install keeps the old one working.
    Write-AgentSecret -Folder $folder -Secret $secret
    [Array]::Clear($secret, 0, $secret.Length)
    $version = if ($result.PSObject.Properties['version'] -and $result.version) { [string]$result.version } else { $package.Version }

    $state['agent'] = [ordered]@{
        user        = 'agent'
        password    = ConvertTo-SecureString ([string]$result.password) -AsPlainText -Force | ConvertFrom-SecureString
        vmId        = $vmId
        version     = $version
        signInAs    = $User
        installedAt = (Get-Date).ToString('o')
    }
    $state['use'] = 'agent'
    Save-GpuVMState $state
    Update-GpuVMNetworkIsolation -Name $Name -State $state
    $streamingSetup = 'none'
    if ($state['streaming'] -and $state['config']['streaming']['virtualDisplay']) {
        $streamingSetup = 'failed'
        try {
            $streamMode = Get-GpuVMStreamMode -State $state
            # Added before the power cycle, so the agent finds the exact mode at boot instead of the closest one.
            $hz = [int]($streamMode -replace '^.*@', '')
            if ($hz -ge 30 -and $hz -le 240 -and $hz -notin 30, 60, 90, 120, 144, 165, 244) { $null = Add-GuestRefreshRate -Name $Name -Credential $credential -Hz $hz }
            $null = Sync-GuestAgentDisplayMode -Name $Name -Credential $credential -Mode $streamMode
            if ($streamMode -match '^(\d+)x(\d+)@(\d+)$') {
                $null = Set-GuestVddPreferredMode -Name $Name -Credential $credential -Width $Matches[1] -Height $Matches[2] -Hz $Matches[3]
            }
            Initialize-GuestStreamingForAgent -Name $Name -Credential $credential
            $streamingSetup = 'ready'
        }
        catch { Write-Warning "Couldn't tell the agent the viewer's display mode: $($_.Exception.Message)" }
    }
    Write-JsonFile -Path (Join-Path $folder 'agent.json') -Data ([ordered]@{
        vmId        = $vmId
        name        = $Name
        folder      = Split-Path $state['statePath'] -Parent
        version     = $version
        installedAt = $state['agent']['installedAt']
    })
    $restart = [bool]($result.PSObject.Properties['rebootNeeded'] -and $result.rebootNeeded)
    if ($restart) {
        # Off and on, not a restart: a restart keeps the GPU partition's state, which can leave the session without a display.
        Restart-GpuVMCold -Name $Name
    }
    $timing['total'] = $sw.ElapsedMilliseconds
    [ordered]@{ name = $Name; vmId = $vmId; version = $version; fastPath = [bool]($result.PSObject.Properties['fastPath'] -and $result.fastPath); exeSent = -not $setup.Same; restarted = $restart; streaming = $streamingSetup; winget = $winget; ms = $timing }
}
