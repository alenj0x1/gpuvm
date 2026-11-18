function Import-GpuVM {
    <#
    .SYNOPSIS
    Creates a VM from a .gpuvm file made with Export-GpuVM. The disk is checked against the fingerprint saved in the
    file; the VM gets its own streaming identity (the viewer pairs again) and its settings from -Profile. If the name
    is taken it gets "<name>-2". Without -Credential, GpuVM asks for the Windows password later.
    .EXAMPLE
    Import-GpuVM -Path D:\Copias\win10.gpuvm -Credential (Get-Credential gpuvm)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidatePattern('^[\w-]{1,40}$')][string]$Name,
        [string]$Profile = 'balanced',
        [pscredential]$Credential,
        [switch]$Start
    )
    Assert-Admin
    $archive = Open-TransferArchive -Path $Path
    $vmDir = $null
    $name = $null
    try {
        $manifest = $archive.Manifest
        $name = if ($Name) { Assert-GpuVMNameFree -Name $Name -Root (Get-GpuVMDefaultRoot); $Name }
            else { Get-FreeGpuVMName -Base $(if ($manifest['name']) { $manifest['name'] } else { 'importada' }) }
        $diskBytes = [int64]$manifest['disk']['bytes']
        $sizeGB = [math]::Ceiling([math]::Max($diskBytes, [int64]$manifest['diskSizeBytes']) / 1GB)
        $config = Resolve-GpuVMProfile -Name $Profile -Override @{ vm = @{ disk = @{ type = 'Dynamic'; sizeGB = $sizeGB } } }
        if ($manifest['cleanup']) { $config['guest']['cleanup'] = $manifest['cleanup'] }
        if ($manifest['user']) { $config['guest']['userName'] = $manifest['user'] }
        if ($config.Contains('iso')) { $config.Remove('iso') }
        $root = $config['vm']['root']
        # The unpacked disk must fit now, and the VM must be able to grow to its size like any other (lab 027 budget).
        $freeGB = Get-DriveFreeGB $root
        $needGB = [math]::Ceiling($diskBytes / 1GB) + $script:DiskMarginGB
        if ($needGB -gt $freeGB) { throw "No hay espacio para importar: el disco ocupa $([math]::Ceiling($diskBytes / 1GB)) GB y quedan $freeGB GB libres." }
        $failed = @(Test-GpuVMHost -Profile $Profile -Override @{ vm = @{ disk = @{ type = 'Dynamic'; sizeGB = [math]::Max(1, $sizeGB - [math]::Floor($diskBytes / 1GB)) } } } |
            Where-Object Status -eq 'Fail')
        if ($failed) { throw ('El equipo no pasa la revisión: ' + (($failed | ForEach-Object { "$($_.Name): $($_.Detail)" }) -join '; ')) }
        if (-not $PSCmdlet.ShouldProcess($name, "Importar desde $Path")) { return }

        Initialize-GpuVMRoot -Path $root
        $vmDir = Join-Path $root $name
        $vhdPath = Join-Path $vmDir "Virtual Hard Disks\$name.vhdx"
        New-Item -ItemType Directory -Path (Split-Path $vhdPath -Parent) -Force | Out-Null
        $in = $archive.DiskEntry.Open()
        $out = [IO.File]::Open($vhdPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $copy = Copy-StreamWithHash -Source $in -Destination $out -Length $diskBytes -Limit $diskBytes -Label 'Importando' }
        finally { $out.Dispose(); $in.Dispose() }
        if ($copy.Bytes -ne $diskBytes -or $copy.Sha256 -ne $manifest['disk']['sha256']) {
            throw 'El disco del archivo no coincide con su huella: el archivo está dañado o fue modificado. No se importa.'
        }
        Write-Step 'Huella del disco verificada'
        $vhd = Get-VHD -Path $vhdPath
        if ($vhd.VhdType -eq 'Differencing') { throw 'El disco del archivo depende de otro disco; no se importa.' }

        $webPassword = New-RandomPassword
        $sunshine = @{ set = $false }
        Invoke-WithMountedWindows -Path $vhdPath -ScriptBlock {
            param($winRoot)
            Write-Step 'Dando a la máquina su propia identidad de streaming'
            Reset-ClonedGuestIdentity -WindowsRoot $winRoot
            $sunshine.set = Set-SunshineWebCredential -WindowsRoot $winRoot -User 'gpuvm' -Password $webPassword
        }

        Write-Step "Registrando la máquina '$name' en Hyper-V"
        New-VM -Name $name -Generation 2 -MemoryStartupBytes ([int64]$config['vm']['memoryGB'] * 1GB) -VHDPath $vhdPath -Path $root | Out-Null
        Invoke-GpuVMBackend -Backend $config['backend'] -Operation Apply -Arguments $name, $config

        $streamingProvider = if ($config['streaming']) { $config['streaming']['provider'] } else { 'sunshine' }
        $state = [ordered]@{
            name          = $name
            backend       = $config['backend']
            profile       = $config['name']
            config        = $config
            vmDir         = $vmDir
            vhdPath       = $vhdPath
            gpu           = [ordered]@{ name = $null; pnpDeviceId = $null; driverVersion = $manifest['driverVersion']; syncedAt = $null }
            createdAt     = (Get-Date).ToString('o')
            importedAt    = (Get-Date).ToString('o')
            importedFrom  = [ordered]@{ name = $manifest['name']; exportedAt = $manifest['exportedAt']; toolVersion = $manifest['toolVersion'] }
            toolVersion   = $script:ToolVersion
            statePath     = Join-Path $vmDir 'gpuvm.json'
            edition       = $manifest['edition']
            streaming     = if ($sunshine.set) {
                [ordered]@{ provider = $streamingProvider; user = 'gpuvm'; password = ConvertTo-SecureString $webPassword -AsPlainText -Force | ConvertFrom-SecureString; pairedClient = $null }
            } else { $null }
            pendingRename = $true
            pendingApps   = @($manifest['pendingApps'])
            installedApps = @($manifest['installedApps'])
        }
        # Without a password GpuVM has no guest credential yet; the app asks for it (the user name is in the profile).
        if ($Credential) { $state['guest'] = [ordered]@{ user = $Credential.UserName; password = $Credential.Password | ConvertFrom-SecureString } }
        Save-GpuVMState $state
    }
    catch {
        if ($name -and $vmDir) {
            Write-Step 'La importación falló; limpiando lo que se alcanzó a crear'
            if (Get-VM -Name $name -ErrorAction SilentlyContinue) { Remove-VM -Name $name -Force -ErrorAction SilentlyContinue }
            $disk = Join-Path $vmDir "Virtual Hard Disks\$name.vhdx"
            if ((Get-VHD -Path $disk -ErrorAction SilentlyContinue).Attached) { Dismount-VHD -Path $disk -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $vmDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    finally { $archive.Zip.Dispose() }

    Write-Step "Máquina '$name' importada"
    if ($Start) {
        try { Assert-VMCanStart -Name $name; Start-VM -Name $name -ErrorAction Stop }
        catch { Write-Warning "La máquina se importó pero no pudo encender: $($_.Exception.Message)" }
    }
    Get-GpuVM -Name $name
}
