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
        [Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name,
        [string]$IsoPath,
        [string]$Profile = 'balanced',
        [hashtable]$Override,
        [string]$Edition,
        [pscredential]$Credential,
        [ValidatePattern('^[\w-]{1,40}$')][string]$Template,
        [switch]$Start
    )
    Assert-Admin
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "Ya existe una VM llamada '$Name'." }
    if ($Template) {
        if ($IsoPath -or $Edition -or $Credential) { throw 'Con -Template, Windows, su edición y su contraseña vienen de la plantilla; quita -IsoPath, -Edition y -Credential.' }
        if (-not $PSCmdlet.ShouldProcess($Name, "Crear VM desde la plantilla $Template")) { return }
        return New-GpuVMFromTemplate -Name $Name -Template $Template -Profile $Profile -Override $Override -Start:$Start
    }

    $failed = @(Test-GpuVMHost -Profile $Profile -Override $Override | Where-Object Status -eq 'Fail')
    if ($failed) {
        throw ('El equipo no pasa la revisión: ' + (($failed | ForEach-Object { "$($_.Name): $($_.Detail)" }) -join '; '))
    }

    $config = Resolve-GpuVMProfile -Name $Profile -Override $Override
    if (-not $IsoPath) { $IsoPath = if ($config.Contains('iso')) { $config['iso'] } }
    if (-not $IsoPath) { throw 'Elige la imagen de Windows (ISO).' }
    $editionName = if ($Edition) { $Edition } else { $config['guest']['edition'] }
    if (-not $Credential) {
        $Credential = Get-Credential -UserName $config['guest']['userName'] -Message 'Usuario y contraseña de la cuenta local del invitado'
    }
    if (-not $Credential) { throw 'Se necesita un usuario para la VM.' }

    $iso = Mount-WindowsIso -IsoPath $IsoPath
    try {
        $image = Select-WindowsEdition -Editions (Get-WindowsEditionList -ImageFile $iso.ImageFile) -Edition $editionName
        $language = Get-WindowsImageLanguage -ImageFile $iso.ImageFile -Index $image.Index
        Write-Step "Edición: $($image.Name) ($language)"

        $unattend = New-UnattendXml -ComputerName (ConvertTo-ComputerName $Name) -UserName $Credential.UserName `
            -Password $Credential.Password -UILanguage $language -AutoLogon ([bool]$config['guest']['autoLogon'])

        if (-not $PSCmdlet.ShouldProcess($Name, "Crear VM con perfil $Profile")) { return }

        $streaming = New-StreamingPayload -Config $config
        $context = @{
            Name        = $Name
            Config      = $config
            ImageFile   = $iso.ImageFile
            ImageIndex  = $image.Index
            UnattendXml = $unattend
            GuestFiles  = if ($streaming) { $streaming.GuestFiles } else { @() }
            GuestJson   = if ($streaming) { $streaming.GuestJson } else { @{} }
        }
        # Only the state returned by the backend counts; any other output that leaks through is discarded.
        $state = @(Invoke-GpuVMBackend -Backend $config['backend'] -Operation New -Arguments (, $context)) |
            Where-Object { $_ -is [System.Collections.IDictionary] } | Select-Object -Last 1
        if (-not $state) { throw "El backend no devolvió el estado de la VM '$Name'. Recupéralo con: ./gpuvm.ps1 repair -Name $Name -Profile $Profile" }
        $state['edition'] = $image.Name
        $state['streaming'] = if ($streaming) { $streaming.State } else { $null }
        # Lets GpuVM fix things inside the VM via PowerShell Direct (session, logs) without prompting.
        $state['guest'] = [ordered]@{ user = $Credential.UserName; password = $Credential.Password | ConvertFrom-SecureString }
        $state['pendingApps'] = @(if ($config['guest'].Contains('apps')) { $config['guest']['apps'] })
        Save-GpuVMState $state
        try { Register-GpuVMIsoUse -Path $IsoPath -VMName $Name } catch { Write-Warning "No se pudo recordar el ISO: $($_.Exception.Message)" }
    }
    finally {
        # Only dismount it if GpuVM mounted it; if the user already had it open, leave it as it was.
        if (-not $iso.WasAttached) { Dismount-DiskImage -ImagePath $iso.IsoPath | Out-Null }
    }

    Write-Step "VM '$Name' lista. La primera vez Windows termina de configurarse solo (unos minutos)."
    if ($state['streaming']) { Write-Step "Para verla con la GPU: ./gpuvm.ps1 connect -Name $Name" }
    if ($Start) {
        try { Assert-VMCanStart -Name $Name; Start-VM -Name $Name -ErrorAction Stop }
        catch { Write-Warning "La VM se creó pero no pudo encender: $($_.Exception.Message)" }
    }
    Get-GpuVM -Name $Name
}

function New-GpuVMFromTemplate {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Template,
        [string]$Profile = 'balanced',
        [hashtable]$Override,
        [switch]$Start
    )
    # Not $template: PowerShell names are case-insensitive, and that would overwrite the -Template string.
    $base = Read-GpuVMTemplate -Name $Template
    # The copy's disk only grows with what it writes: the host check must not ask for a profile's fixed disk.
    $diskOverride = @{ vm = @{ disk = @{ type = 'Dynamic'; sizeGB = [int]$base['sizeGB'] } } }
    $checkOverride = if ($Override) { Merge-Hashtable -Base $Override -Override $diskOverride } else { $diskOverride }
    $failed = @(Test-GpuVMHost -Profile $Profile -Override $checkOverride | Where-Object Status -eq 'Fail')
    if ($failed) {
        throw ('El equipo no pasa la revisión: ' + (($failed | ForEach-Object { "$($_.Name): $($_.Detail)" }) -join '; '))
    }
    $config = New-TemplateCloneConfig -Config (Resolve-GpuVMProfile -Name $Profile -Override $Override) -Template $base

    $context = @{ Name = $Name; Config = $config; Template = $base }
    $state = @(Invoke-GpuVMBackend -Backend $config['backend'] -Operation Clone -Arguments (, $context)) |
        Where-Object { $_ -is [System.Collections.IDictionary] } | Select-Object -Last 1
    if (-not $state) { throw "El backend no devolvió el estado de la VM '$Name'." }
    $state['edition'] = $base['edition']
    # Sunshine keeps the template's web credentials; Moonlight pairs again with the copy's new identity.
    $state['streaming'] = $base['streaming']
    $state['guest'] = $base['guest']
    $state['pendingRename'] = $true
    $state['pendingApps'] = @(if ($base.Contains('pendingApps')) { $base['pendingApps'] })
    Save-GpuVMState $state

    Write-Step "VM '$Name' lista sobre la plantilla '$Template'."
    if ($Start) {
        try { Assert-VMCanStart -Name $Name; Start-VM -Name $Name -ErrorAction Stop }
        catch { Write-Warning "La VM se creó pero no pudo encender: $($_.Exception.Message)" }
    }
    Get-GpuVM -Name $Name
}
