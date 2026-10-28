function New-GpuVM {
    <#
    .SYNOPSIS
    Creates a Windows 10/11 VM with the host GPU, installed unattended from an ISO. Without -IsoPath it uses
    the profile's ISO. The profile's apps (guest.apps) are installed the first time the VM is opened.
    .EXAMPLE
    New-GpuVM -Name win11 -IsoPath D:\ISOs\Win11.iso -Profile max-performance
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name,
        [string]$IsoPath,
        [string]$Profile = 'balanced',
        [hashtable]$Override,
        [string]$Edition,
        [pscredential]$Credential,
        [switch]$Start
    )
    Assert-Admin
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "Ya existe una VM llamada '$Name'." }

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
