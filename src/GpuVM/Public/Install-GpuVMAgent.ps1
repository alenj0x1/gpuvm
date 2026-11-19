function Install-GpuVMAgent {
    <#
    .SYNOPSIS
    Installs (or reinstalls) GpuVM's agent inside a running VM, with a new per-VM secret and a new password for the
    standard Windows user `agent` it works as. Also the fast path for a copy of a template that already has the agent.

    .DESCRIPTION
    The secret K (32 random bytes) is kept on this PC with DPAPI in ProgramData\GpuVM\agents\<vmid>\secret, readable
    by SYSTEM only (the GpuVM service). Over PowerShell Direct, with the machine's saved administrator account:
    gpuvm-agent.exe is copied (Copy-Item -ToSession) into a folder only Administrators and SYSTEM can open, unless the
    same build is already installed; guest\agent\install.ps1 runs as a script block (guests keep the Restricted
    execution policy) with that folder and K, writes K with a SYSTEM + Administrators ACL (never KVP: every guest user
    can read KVP, lab 050), creates or updates `agent`, rotates its password and restarts the agent's service. The
    password is kept like the machine's own account (DPAPI) in gpuvm.json. When the installer asks for it, Windows
    restarts from inside the guest (Restart-VM right after it lost the service and sign-in changes).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        # Who Windows signs in as: the agent's own standard user (default), or the person's user as configured before.
        [ValidateSet('agent', 'own')][string]$User = 'agent'
    )
    # Any failure stops the install: it never reports success with a step left undone (lab 052: a denied secret
    # move was a non-terminating error and the caller was told it worked).
    $ErrorActionPreference = 'Stop'
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    $vm = Get-VM -Name $Name -ErrorAction Stop
    if ($vm.State -ne 'Running') { throw "Start '$Name' first: the agent is installed into the running machine." }
    $credential = Get-GpuVMGuestCredential -State $state
    # An agent machine is isolated on the Default Switch or an internal one (review 2, #3): checked before the guest
    # gets anything.
    Assert-AgentSwitch -Name $Name
    if (-not $credential) { throw "GpuVM doesn't know the account of '$Name'. Save it first (Set-GpuVMGuestCredential)." }
    $package = Get-AgentPackage
    $vmId = $vm.Id.Guid.ToLowerInvariant()
    $folder = Join-Path (Get-GpuVMAgentRoot) $vmId
    Initialize-AgentFolder -Path (Get-GpuVMAgentRoot)
    Initialize-AgentFolder -Path $folder
    $timing = [ordered]@{}
    $sw = [Diagnostics.Stopwatch]::StartNew()

    # Windows' first-time setup (optimizations, streaming) runs at the first sign-in of the machine's own account.
    # Switching the sign-in to `agent` before it ran would skip it for good (and for every copy of a template made
    # from this machine), so it is waited for first.
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
        # A folder only Administrators and SYSTEM can open, for the exe while it is installed.
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
                # A copy of a template with this build: the installed exe goes back in as the source, nothing crosses.
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
    # A machine with the agent is an agent machine (Set-GpuVMUse none takes it back), and always isolated.
    $state['use'] = 'agent'
    Save-GpuVMState $state
    Update-GpuVMNetworkIsolation -Name $Name -State $state
    Write-JsonFile -Path (Join-Path $folder 'agent.json') -Data ([ordered]@{
        vmId        = $vmId
        name        = $Name
        folder      = Split-Path $state['statePath'] -Parent
        version     = $version
        installedAt = $state['agent']['installedAt']
    })
    $restart = [bool]($result.PSObject.Properties['rebootNeeded'] -and $result.rebootNeeded)
    if ($restart) {
        Write-Step 'Restarting Windows in the machine'
        Invoke-Command -VMName $Name -Credential $credential -ScriptBlock { Restart-Computer -Force } -ErrorAction SilentlyContinue
    }
    $timing['total'] = $sw.ElapsedMilliseconds
    [ordered]@{ name = $Name; vmId = $vmId; version = $version; fastPath = [bool]($result.PSObject.Properties['fastPath'] -and $result.fastPath); exeSent = -not $setup.Same; restarted = $restart; ms = $timing }
}
