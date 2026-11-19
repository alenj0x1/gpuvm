function New-GpuVM {
    <#
    .SYNOPSIS
    Creates a Windows 10/11 VM with the host GPU, installed unattended from an ISO. Without -IsoPath it uses
    the profile's ISO. The profile's apps (guest.apps) are installed the first time the VM is opened.
    With -Template it builds on a saved template instead (ready in seconds, no ISO or password): Windows, its apps,
    cleanup level and password come from the template; processors, memory, GPU and Moonlight from the profile.
    .EXAMPLE
    New-GpuVM -Name win11 -IsoPath D:\ISOs\Win11.iso -Profile max-performance
    New-GpuVM -Name juegos-2 -Template juegos-base -Start
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidatePattern('^[\w-]{1,40}$')][string]$Name,
        [string]$IsoPath,
        [string]$Profile = 'balanced',
        [hashtable]$Override,
        [string]$Edition,
        [pscredential]$Credential,
        [ValidatePattern('^[\w-]{1,40}$')][string]$Template,
        [switch]$Start,
        # A throwaway copy of -Template: it starts now and is deleted with its disk once it is turned off.
        # Without -Name it is called "<template>-desechable" (or -2, -3...).
        [switch]$Disposable,
        # For GpuVM's agent: installs it once Windows is up (Set-GpuVMUse), signing in as `agent` or the person's user.
        [ValidateSet('agent')][string]$Use,
        [ValidateSet('agent', 'own')][string]$AgentUser = 'agent'
    )
    Assert-Admin
    if ($Disposable) {
        if (-not $Template) { throw 'A disposable machine is made from a template (-Template).' }
        if (-not $Name) { $Name = Get-FreeGpuVMName -Base ($Template.Substring(0, [math]::Min($Template.Length, 29)) + '-desechable') }
        $Start = $true
    }
    if (-not $Name) { throw 'Choose a name for the machine (-Name).' }
    Assert-GpuVMNameFree -Name $Name
    if ($Template) {
        if ($IsoPath -or $Edition -or $Credential) { throw 'With -Template, Windows, its edition and its password come from the template; remove -IsoPath, -Edition and -Credential.' }
        if (-not $PSCmdlet.ShouldProcess($Name, "Create VM from the template $Template")) { return }
        $made = New-GpuVMFromTemplate -Name $Name -Template $Template -Profile $Profile -Override $Override -Start:$Start -Disposable:$Disposable
        if (-not $Use) { return $made }
        Initialize-GpuVMAgentUse -Name $Name -User $AgentUser
        return Get-GpuVM -Name $Name
    }

    $failed = @(Test-GpuVMHost -Profile $Profile -Override $Override | Where-Object Status -eq 'Fail')
    if ($failed) {
        throw ("This PC doesn't pass the check: " + (($failed | ForEach-Object { "$($_.Name): $($_.Detail)" }) -join '; '))
    }

    $config = Resolve-GpuVMProfile -Name $Profile -Override $Override
    if (-not $IsoPath) { $IsoPath = if ($config.Contains('iso')) { $config['iso'] } }
    if (-not $IsoPath) { throw 'Choose the Windows image (ISO).' }
    $editionName = if ($Edition) { $Edition } else { $config['guest']['edition'] }
    if (-not $Credential) {
        $Credential = Get-Credential -UserName $config['guest']['userName'] -Message 'User name and password for the guest''s local account'
    }
    if (-not $Credential) { throw 'The VM needs a user name.' }

    $iso = Mount-WindowsIso -IsoPath $IsoPath
    try {
        $image = Select-WindowsEdition -Editions (Get-WindowsEditionList -ImageFile $iso.ImageFile) -Edition $editionName
        $language = Get-WindowsImageLanguage -ImageFile $iso.ImageFile -Index $image.Index
        Write-Step "Edition: $($image.Name) ($language)"

        $unattend = New-UnattendXml -ComputerName (ConvertTo-ComputerName $Name) -UserName $Credential.UserName `
            -Password $Credential.Password -UILanguage $language -AutoLogon ([bool]$config['guest']['autoLogon'])

        if (-not $PSCmdlet.ShouldProcess($Name, "Create VM with profile $Profile")) { return }

        $streaming = New-StreamingPayload -Config $config
        $context = @{
            Name        = $Name
            Config      = $config
            ImageFile   = $iso.ImageFile
            ImageIndex  = $image.Index
            Edition     = $image.Name
            Language    = $language
            UnattendXml = $unattend
            GuestFiles  = if ($streaming) { $streaming.GuestFiles } else { @() }
            GuestJson   = if ($streaming) { $streaming.GuestJson } else { @{} }
        }
        # Only the state returned by the backend counts; any other output that leaks through is discarded.
        $state = @(Invoke-GpuVMBackend -Backend $config['backend'] -Operation New -Arguments (, $context)) |
            Where-Object { $_ -is [System.Collections.IDictionary] } | Select-Object -Last 1
        if (-not $state) { throw "The backend didn't return the state of the VM '$Name'. Recover it with: ./gpuvm.ps1 repair -Name $Name -Profile $Profile" }
        $state['edition'] = $image.Name
        $state['streaming'] = if ($streaming) { $streaming.State } else { $null }
        # Lets GpuVM fix things inside the VM via PowerShell Direct (session, logs) without prompting.
        $state['guest'] = [ordered]@{ user = $Credential.UserName; password = $Credential.Password | ConvertFrom-SecureString }
        $state['pendingApps'] = @(if ($config['guest'].Contains('apps')) { $config['guest']['apps'] })
        Save-GpuVMState $state
        try { Register-GpuVMIsoUse -Path $IsoPath -VMName $Name } catch { Write-Warning "Couldn't remember the ISO: $($_.Exception.Message)" }
    }
    finally {
        # Only dismount it if GpuVM mounted it; if the user already had it open, leave it as it was.
        if (-not $iso.WasAttached) { Dismount-DiskImage -ImagePath $iso.IsoPath | Out-Null }
    }

    Write-Step "VM '$Name' is ready. The first time, Windows finishes setting itself up (a few minutes)."
    if ($state['streaming']) { Write-Step "To see it with the GPU: ./gpuvm.ps1 connect -Name $Name" }
    if ($Start) {
        try { Assert-VMCanStart -Name $Name; Start-VM -Name $Name -ErrorAction Stop }
        catch { Write-Warning "The VM was created but couldn't turn on: $($_.Exception.Message)" }
    }
    if ($Use) { Initialize-GpuVMAgentUse -Name $Name -User $AgentUser }
    Get-GpuVM -Name $Name
}

function New-GpuVMFromTemplate {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Template,
        [string]$Profile = 'balanced',
        [hashtable]$Override,
        [switch]$Start,
        [switch]$Disposable
    )
    # Not $template: PowerShell names are case-insensitive, and that would overwrite the -Template string.
    $base = Read-GpuVMTemplate -Name $Template
    # The copy's disk only grows with what it writes: the host check must not ask for a profile's fixed disk.
    $diskOverride = @{ vm = @{ disk = @{ type = 'Dynamic'; sizeGB = [int]$base['sizeGB'] } } }
    $checkOverride = if ($Override) { Merge-Hashtable -Base $Override -Override $diskOverride } else { $diskOverride }
    $failed = @(Test-GpuVMHost -Profile $Profile -Override $checkOverride | Where-Object Status -eq 'Fail')
    if ($Disposable) {
        # A disposable machine reserves a fixed amount, not the template's full size: it is shut down (and deleted) if
        # the drive gets near the host's margin (Remove-GpuVMDisposable).
        $failed = @($failed | Where-Object Name -ne 'Disk')
        $budget = Get-GpuVMDiskBudget -Root (Get-GpuVMDefaultRoot)
        if ($budget['availableGB'] -lt $script:DisposableReserveGB) {
            $failed += New-CheckResult 'Disk' Fail ("A disposable machine needs $($script:DisposableReserveGB) GB free on $($budget['drive']) " +
                "besides what is reserved for the other machines; there are $($budget['availableGB']) GB.")
        }
    }
    if ($failed) {
        throw ("This PC doesn't pass the check: " + (($failed | ForEach-Object { "$($_.Name): $($_.Detail)" }) -join '; '))
    }
    $config = New-TemplateCloneConfig -Config (Resolve-GpuVMProfile -Name $Profile -Override $Override) -Template $base

    $context = @{ Name = $Name; Config = $config; Template = $base }
    $state = @(Invoke-GpuVMBackend -Backend $config['backend'] -Operation Clone -Arguments (, $context)) |
        Where-Object { $_ -is [System.Collections.IDictionary] } | Select-Object -Last 1
    if (-not $state) { throw "The backend didn't return the state of the VM '$Name'." }
    $state['edition'] = $base['edition']
    # Sunshine keeps the template's web credentials; Moonlight pairs again with the copy's new identity.
    $state['streaming'] = $base['streaming']
    $state['guest'] = $base['guest']
    $state['pendingRename'] = $true
    $state['pendingApps'] = @(if ($base.Contains('pendingApps')) { $base['pendingApps'] })
    $state['installedApps'] = @(if ($base.Contains('installedApps')) { $base['installedApps'] })
    if ($Disposable) { $state['disposable'] = [ordered]@{ createdAt = (Get-Date).ToString('o'); startedAt = $null } }
    Save-GpuVMState $state

    Write-Step "VM '$Name' is ready, based on the template '$Template'."
    if ($Start) {
        try { Assert-VMCanStart -Name $Name; Start-VM -Name $Name -ErrorAction Stop; Set-GpuVMDisposableStarted -State $state }
        catch { Write-Warning "The VM was created but couldn't turn on: $($_.Exception.Message)" }
    }
    Get-GpuVM -Name $Name
}
