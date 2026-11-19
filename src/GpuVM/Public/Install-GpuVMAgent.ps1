function Install-GpuVMAgent {
    <#
    .SYNOPSIS
    Installs (or reinstalls) GpuVM's agent inside a running VM: a new per-VM secret, the agent's files, and the
    standard Windows user `agent` it works as. Reinstalling replaces the secret (the old one stops working).

    .DESCRIPTION
    The secret K (32 random bytes) is kept on this PC with DPAPI in ProgramData\GpuVM\agents\<vmid>\secret, readable
    by SYSTEM only (the GpuVM service). It reaches the guest through the Guest Service Interface (Copy-VMFile), which
    is turned on only for the copy when it was off, into C:\ProgramData\GpuVM\Agent (SYSTEM and Administrators only).
    Never through KVP: every guest user can read KVP (lab 050). guest\agent\install.ps1 then runs inside the VM over
    PowerShell Direct with the machine's saved account and returns the `agent` user's password, kept like the
    machine's own (DPAPI) in gpuvm.json.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    $vm = Get-VM -Name $Name -ErrorAction Stop
    if ($vm.State -ne 'Running') { throw "Start '$Name' first: the agent is installed into the running machine." }
    $credential = Get-GpuVMGuestCredential -State $state
    if (-not $credential) { throw "GpuVM doesn't know the account of '$Name'. Save it first (Set-GpuVMGuestCredential)." }
    $package = Get-AgentPackage
    $vmId = $vm.Id.Guid.ToLowerInvariant()
    $folder = Join-Path (Get-GpuVMAgentRoot) $vmId
    Initialize-AgentFolder -Path (Get-GpuVMAgentRoot)
    Initialize-AgentFolder -Path $folder

    $secret = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($secret)
    # The plain copy that Copy-VMFile sends exists only during the copy, in the administrators-only folder.
    $plain = Join-Path $folder "copy-$([guid]::NewGuid().ToString('n'))"
    $gsi = Get-GuestServiceInterface -Name $Name
    $enabledHere = $false
    try {
        Write-Step 'Preparing the agent''s folder in the machine'
        Invoke-Command -VMName $Name -Credential $credential -ErrorAction Stop -ArgumentList $script:GuestAgentDir -ScriptBlock {
            param($dir)
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            # SYSTEM and Administrators only (by SID: names are translated in a localized Windows).
            & icacls.exe $dir /setowner '*S-1-5-32-544' /Q | Out-Null
            & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /Q | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Couldn't restrict $dir." }
            $staging = Join-Path $dir 'staging'
            if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
        }
        if ($gsi -and -not $gsi.Enabled) {
            Enable-VMIntegrationService -VMName $Name -Name $gsi.Name
            $enabledHere = $true
        }
        Write-Step 'Copying the agent into the machine'
        [IO.File]::WriteAllBytes($plain, $secret)
        Copy-AgentFileToGuest -Name $Name -Source $plain -Destination (Join-Path $script:GuestAgentDir 'secret')
        Remove-Item -LiteralPath $plain -Force
        foreach ($file in $package.Files) {
            $relative = [IO.Path]::GetRelativePath($package.Dist, $file.FullName)
            Copy-AgentFileToGuest -Name $Name -Source $file.FullName -Destination (Join-Path (Join-Path $script:GuestAgentDir 'staging') $relative)
        }
    }
    finally {
        if (Test-Path -LiteralPath $plain) { Remove-Item -LiteralPath $plain -Force }
        if ($enabledHere) { Disable-VMIntegrationService -VMName $Name -Name $gsi.Name -ErrorAction SilentlyContinue }
    }
    # The host side's copy is written only once the guest has it, so a failed install keeps the old one working.
    Write-AgentSecret -Folder $folder -Secret $secret
    [Array]::Clear($secret, 0, $secret.Length)

    Write-Step 'Installing the agent and its user'
    # guest\agent\install.ps1 -Staging <folder> (named arguments: the script's text runs in the guest).
    $code = Get-Content -Raw -LiteralPath $package.Install
    $output = @(Invoke-Command -VMName $Name -Credential $credential -ErrorAction Stop -ArgumentList $code, (Join-Path $script:GuestAgentDir 'staging') -ScriptBlock {
        param($code, $staging) & ([scriptblock]::Create($code)) -Staging $staging
    })
    $result = $output | Where-Object { $_ -and $_.PSObject.Properties['password'] } | Select-Object -Last 1
    if (-not $result -or -not $result.password) { throw 'The agent''s installer in the machine didn''t return the agent user''s password.' }
    $version = if ($result.PSObject.Properties['version'] -and $result.version) { [string]$result.version } else { $package.Version }

    $state['agent'] = [ordered]@{
        user        = 'agent'
        password    = ConvertTo-SecureString ([string]$result.password) -AsPlainText -Force | ConvertFrom-SecureString
        vmId        = $vmId
        version     = $version
        installedAt = (Get-Date).ToString('o')
    }
    Save-GpuVMState $state
    Write-JsonFile -Path (Join-Path $folder 'agent.json') -Data ([ordered]@{
        vmId        = $vmId
        name        = $Name
        folder      = Split-Path $state['statePath'] -Parent
        version     = $version
        installedAt = $state['agent']['installedAt']
    })
    [ordered]@{ name = $Name; vmId = $vmId; version = $version }
}
