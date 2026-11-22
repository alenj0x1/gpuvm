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
        [ValidateSet('agent', 'own')][string]$AgentUser = 'agent',
        # Set by GpuVM's service for an agent session (never needed by hand): only a template made for agents
        # (template.json use = agent) is copied, and the copy is an agent machine, isolated.
        [switch]$ForAgent
    )
    Assert-Admin
    if ($ForAgent -and -not $Template) { throw 'An agent session only makes copies of a template made for agents.' }
    if ($Use -eq 'agent') {
        $Override = Add-DefaultMemory -Override $Override -MemoryGB $script:AgentMemoryGB
        # Its first-time setup must not turn the Hyper-V display off (the agent needs a display before any viewer).
        $Override = Merge-Hashtable -Base $(if ($Override) { $Override } else { @{} }) -Override @{ streaming = @{ disableHyperVVideo = $false } }
    }
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
        $made = New-GpuVMFromTemplate -Name $Name -Template $Template -Profile $Profile -Override $Override -Start:$Start -Disposable:$Disposable `
            -ProfileGiven:$PSBoundParameters.ContainsKey('Profile') -ForAgent:$ForAgent
        if (-not $Use) { return $made }
        Initialize-GpuVMAgentUse -Name $Name -User $AgentUser
        $startResult = if ($made -and $made.PSObject.Properties['Started']) { @{ started = $made.Started; startError = $made.StartError; neededGB = $made.NeededGB; freeGB = $made.FreeGB } }
        return Add-StartResult -Info (Get-GpuVM -Name $Name) -Start $startResult
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
    $startResult = if ($Start) { Start-NewGpuVM -Name $Name }
    if ($Use) { Initialize-GpuVMAgentUse -Name $Name -User $AgentUser }
    Add-StartResult -Info (Get-GpuVM -Name $Name) -Start $startResult
}

function New-GpuVMFromTemplate {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Template,
        [string]$Profile = 'balanced',
        [hashtable]$Override,
        [switch]$Start,
        [switch]$Disposable,
        [switch]$ProfileGiven,
        [switch]$ForAgent
    )
    # Not $template: PowerShell names are case-insensitive, and that would overwrite the -Template string.
    $base = Read-GpuVMTemplate -Name $Template
    if (-not $ProfileGiven) { $Override = Get-TemplateMachineOverride -Template $base -Override $Override }
    # The copy's disk only grows with what it writes: the host check must not ask for a profile's fixed disk.
    $diskOverride = @{ vm = @{ disk = @{ type = 'Dynamic'; sizeGB = [int]$base['sizeGB'] } } }
    $checkOverride = if ($Override) { Merge-Hashtable -Base $Override -Override $diskOverride } else { $diskOverride }
    $failed = @(Test-GpuVMHost -Profile $Profile -Override $checkOverride | Where-Object Status -eq 'Fail')
    if ($Disposable) {
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
    $agentCopy = [string]$base['use'] -eq 'agent'
    if ($ForAgent -and -not $agentCopy) {
        throw "An agent session can only copy a template made for agents, and '$Template' isn't one (its source wasn't an agent machine)."
    }
    if ($agentCopy) {
        Set-AgentNetworkIsolation -Config $config
        Set-AgentKeepsHyperVVideo -Config $config
    }

    $context = @{ Name = $Name; Config = $config; Template = $base }
    $state = @(Invoke-GpuVMBackend -Backend $config['backend'] -Operation Clone -Arguments (, $context)) |
        Where-Object { $_ -is [System.Collections.IDictionary] } | Select-Object -Last 1
    if (-not $state) { throw "The backend didn't return the state of the VM '$Name'." }
    $state['edition'] = $base['edition']
    $state['streaming'] = $base['streaming']
    $state['guest'] = $base['guest']
    $state['pendingRename'] = $true
    if ($base['gamepad']) { $state['gamepad'] = [string]$base['gamepad'] }
    $state['pendingApps'] = @(if ($base.Contains('pendingApps')) { $base['pendingApps'] })
    $state['installedApps'] = @(if ($base.Contains('installedApps')) { $base['installedApps'] })
    if ($Disposable) { $state['disposable'] = [ordered]@{ createdAt = (Get-Date).ToString('o'); startedAt = $null } }
    if ($agentCopy) {
        $state['use'] = 'agent'
        $state['agent'] = [ordered]@{ pending = $true; signInAs = $(if ($base['agentSignInAs'] -eq 'own') { 'own' } else { 'agent' }) }
        if ($base['updatedAt'] -and $base['components'] -and -not (Test-GpuVMTemplateStale -Template $base)) { $state['streamingFromTemplate'] = $true }
    }
    Save-GpuVMState $state

    Write-Step "VM '$Name' is ready, based on the template '$Template'."
    $startResult = if ($Start) { Start-NewGpuVM -Name $Name -State $state }
    Add-StartResult -Info (Get-GpuVM -Name $Name) -Start $startResult
}

function Start-NewGpuVM {
    param([Parameter(Mandatory)][string]$Name, [System.Collections.IDictionary]$State)
    try {
        Assert-VMCanStart -Name $Name
        Start-VM -Name $Name -ErrorAction Stop
        if ($State) { Set-GpuVMDisposableStarted -State $State }
        @{ started = $true; startError = $null; neededGB = $null; freeGB = $null }
    }
    catch {
        $message = $_.Exception.Message
        Write-Warning "The VM was created but couldn't turn on: $message"
        $needed = $null
        $free = $null
        if ($message -match 'needs ([\d.,]+) GB free and there are ([\d.,]+) GB') {
            $needed = [double]($Matches[1] -replace ',', '.')
            $free = [double]($Matches[2] -replace ',', '.')
        }
        @{ started = $false; startError = $message; neededGB = $needed; freeGB = $free }
    }
}

function Add-StartResult {
    param($Info, [System.Collections.IDictionary]$Start)
    if ($Info -and $Info.PSObject.Properties['Name'] -and -not $Info.PSObject.Properties['vmId']) {
        $id = try { [string](Get-VM -Name $Info.Name -ErrorAction Stop).Id.Guid } catch { $null }
        if ($id) { $Info | Add-Member -NotePropertyName vmId -NotePropertyValue $id.ToLowerInvariant() -Force }
    }
    if ($Start -and $Info) {
        foreach ($k in 'started', 'startError', 'neededGB', 'freeGB') {
            $Info | Add-Member -NotePropertyName $k -NotePropertyValue $Start[$k] -Force
        }
    }
    $Info
}

$script:AgentMemoryGB = 4

function Add-DefaultMemory {
    param([hashtable]$Override, [Parameter(Mandatory)][int]$MemoryGB)
    $copy = @{}
    if ($Override) { foreach ($k in $Override.Keys) { $copy[$k] = $Override[$k] } }
    $vm = @{}
    if ($copy['vm'] -is [System.Collections.IDictionary]) { foreach ($k in $copy['vm'].Keys) { $vm[$k] = $copy['vm'][$k] } }
    if (-not $vm.Contains('memoryGB')) { $vm['memoryGB'] = $MemoryGB }
    $copy['vm'] = $vm
    $copy
}

function Get-TemplateMachineOverride {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Template, [hashtable]$Override)
    $source = if ($Template['config'] -is [System.Collections.IDictionary]) { $Template['config']['vm'] }
    $copy = @{}
    if ($Override) { foreach ($k in $Override.Keys) { $copy[$k] = $Override[$k] } }
    $vm = @{}
    if ($copy['vm'] -is [System.Collections.IDictionary]) { foreach ($k in $copy['vm'].Keys) { $vm[$k] = $copy['vm'][$k] } }
    if ($source) {
        if (-not $vm.Contains('memoryGB') -and $source['memoryGB']) { $vm['memoryGB'] = [int]$source['memoryGB'] }
        $count = if ($source['cpu'] -is [System.Collections.IDictionary]) { $source['cpu']['count'] }
        if ($count) {
            $cpu = @{}
            if ($vm['cpu'] -is [System.Collections.IDictionary]) { foreach ($k in $vm['cpu'].Keys) { $cpu[$k] = $vm['cpu'][$k] } }
            if (-not $cpu.Contains('count')) { $cpu['count'] = [int]$count }
            $vm['cpu'] = $cpu
        }
    }
    $copy['vm'] = $vm
    $copy
}

function Set-AgentNetworkIsolation {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $vm = $Config['vm']
    if (-not ($vm -is [System.Collections.IDictionary])) { return }
    $network = $vm['network']
    if ($network -is [System.Collections.IDictionary] -and $network.Contains('isolation') -and $network['isolation'] -eq $false) { $network['isolation'] = $true }
}

function Set-AgentKeepsHyperVVideo {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    if ($Config['streaming'] -is [System.Collections.IDictionary]) { $Config['streaming']['disableHyperVVideo'] = $false }
}
