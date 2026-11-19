function Import-GpuVM {
    <#
    .SYNOPSIS
    Creates a VM from a .gpuvm file made with Export-GpuVM. The disk is checked against the fingerprint saved in the
    file; the VM gets its own streaming identity (the viewer pairs again) and its settings from -Profile. If the name
    is taken it gets "<name>-2". The Windows password is needed: the first time the VM is opened, GpuVM uses it to give
    Sunshine inside the copy its own identity and web login.
    .EXAMPLE
    Import-GpuVM -Path D:\Copias\win10.gpuvm -Credential (Get-Credential gpuvm)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidatePattern('^[\w-]{1,40}$')][string]$Name,
        [string]$Profile = 'balanced',
        [hashtable]$Override,
        [Parameter(Mandatory)][pscredential]$Credential,
        [switch]$Start
    )
    Assert-Admin
    $archive = Open-TransferArchive -Path $Path
    $vmDir = $null
    # Not $name: PowerShell names ignore case and that is the validated -Name parameter.
    $vmName = $null
    try {
        $manifest = $archive.Manifest
        $vmName = if ($Name) { Assert-GpuVMNameFree -Name $Name -Root (Get-GpuVMDefaultRoot); $Name }
            else { Get-FreeGpuVMName -Base $(if ($manifest['name']) { $manifest['name'] } else { 'importada' }) }
        $diskBytes = [int64]$manifest['disk']['bytes']
        # Profiles ask for at least 64 GB: a smaller disk grows to that when the VM is set up (Windows extends C: on its
        # next start, as when the disk is enlarged in Options).
        $sizeGB = [math]::Max(64, [math]::Ceiling([math]::Max($diskBytes, [int64]$manifest['diskSizeBytes']) / 1GB))
        # The disk is the file's: its size and type win over the profile and the override.
        $diskOverride = @{ vm = @{ disk = @{ type = 'Dynamic'; sizeGB = $sizeGB } } }
        $config = Resolve-GpuVMProfile -Name $Profile -Override $(if ($Override) { Merge-Hashtable -Base $Override -Override $diskOverride } else { $diskOverride })
        if ($manifest['cleanup']) { $config['guest']['cleanup'] = $manifest['cleanup'] }
        if ($manifest['user']) { $config['guest']['userName'] = $manifest['user'] }
        if ($config.Contains('iso')) { $config.Remove('iso') }
        $root = $config['vm']['root']
        # The unpacked disk must fit now, and the VM must be able to grow to its size like any other (lab 027 budget).
        $freeGB = Get-DriveFreeGB $root
        $needGB = [math]::Ceiling($diskBytes / 1GB) + $script:DiskMarginGB
        if ($needGB -gt $freeGB) { throw "There's no room to import: the disk takes $([math]::Ceiling($diskBytes / 1GB)) GB and $freeGB GB are free." }
        # Same rule as any new machine: its disk at full size must fit next to what the other disks may still grow.
        $checkOverride = if ($Override) { Merge-Hashtable -Base $Override -Override $diskOverride } else { $diskOverride }
        $failed = @(Test-GpuVMHost -Profile $Profile -Override $checkOverride | Where-Object Status -eq 'Fail')
        if ($failed) { throw ("This PC doesn't pass the check: " + (($failed | ForEach-Object { "$($_.Name): $($_.Detail)" }) -join '; ')) }
        if (-not $PSCmdlet.ShouldProcess($vmName, "Import from $Path")) { return }

        Initialize-GpuVMRoot -Path $root
        $vmDir = Join-Path $root $vmName
        $vhdPath = Join-Path $vmDir "Virtual Hard Disks\$vmName.vhdx"
        New-Item -ItemType Directory -Path (Split-Path $vhdPath -Parent) -Force | Out-Null
        $in = $archive.DiskEntry.Open()
        $out = [IO.File]::Open($vhdPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $copy = Copy-StreamWithHash -Source $in -Destination $out -Length $diskBytes -Limit $diskBytes -Label 'Importando' }
        finally { $out.Dispose(); $in.Dispose() }
        if ($copy.Bytes -ne $diskBytes -or $copy.Sha256 -ne $manifest['disk']['sha256']) {
            throw 'The file''s disk doesn''t match its fingerprint: the file is damaged or was changed. It isn''t imported.'
        }
        Write-Step 'Disk fingerprint checked'
        $vhd = Get-VHD -Path $vhdPath
        if ($vhd.VhdType -eq 'Differencing') { throw 'The file''s disk depends on another disk; it isn''t imported.' }

        # The disk comes from a file of unknown origin: it is never mounted on this PC. Sunshine's identity and web login
        # are reset inside the VM, over PowerShell Direct, the first time it is opened (Connect-GpuVM).
        $webPassword = New-RandomPassword

        Write-Step "Registering the machine '$vmName' in Hyper-V"
        New-VM -Name $vmName -Generation 2 -MemoryStartupBytes ([int64]$config['vm']['memoryGB'] * 1GB) -VHDPath $vhdPath -Path $root | Out-Null
        Invoke-GpuVMBackend -Backend $config['backend'] -Operation Apply -Arguments $vmName, $config

        $streamingProvider = if ($config['streaming']) { $config['streaming']['provider'] } else { 'sunshine' }
        $state = [ordered]@{
            name          = $vmName
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
            streaming     = [ordered]@{ provider = $streamingProvider; user = 'gpuvm'; password = ConvertTo-SecureString $webPassword -AsPlainText -Force | ConvertFrom-SecureString; pairedClient = $null }
            pendingIdentityReset = $true
            pendingRename = $true
            pendingApps   = @($manifest['pendingApps'])
            installedApps = @($manifest['installedApps'])
        }
        $state['guest'] = [ordered]@{ user = $Credential.UserName; password = $Credential.Password | ConvertFrom-SecureString }
        Save-GpuVMState $state
    }
    catch {
        if ($vmName -and $vmDir) {
            Write-Step 'The import failed; cleaning up what was made'
            if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) { Remove-VM -Name $vmName -Force -ErrorAction SilentlyContinue }
            $disk = Join-Path $vmDir "Virtual Hard Disks\$vmName.vhdx"
            $vhdInfo = Get-VHD -Path $disk -ErrorAction SilentlyContinue; if ($vhdInfo -and $vhdInfo.Attached) { Dismount-VHD -Path $disk -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $vmDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    finally { $archive.Zip.Dispose() }

    Write-Step "Machine '$vmName' imported"
    if ($Start) {
        try { Assert-VMCanStart -Name $vmName; Start-VM -Name $vmName -ErrorAction Stop }
        catch { Write-Warning "The machine was imported but couldn't turn on: $($_.Exception.Message)" }
    }
    Get-GpuVM -Name $vmName
}
