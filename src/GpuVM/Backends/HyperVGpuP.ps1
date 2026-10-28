# Hyper-V GPU-P (GPU Partitioning) backend: the GPU is shared between the host and the VM.
# The guest uses the same driver as the host, copied to C:\Windows\System32\HostDriverStore.

# Partition values are relative: 1e9 is the maximum for VRAM, decode and compute; UInt64.MaxValue for encode.
function Get-GpuPartitionSettings {
    param([ValidateRange(1, 100)][int]$Percent = 100)
    $scale = [decimal]$Percent / 100
    $base = [uint64][math]::Round(1000000000 * $scale)
    $encode = [uint64]([decimal][uint64]::MaxValue * $scale)
    $settings = @{}
    foreach ($kind in 'VRAM', 'Decode', 'Compute') {
        foreach ($bound in 'Min', 'Max', 'Optimal') { $settings["${bound}Partition$kind"] = $base }
    }
    foreach ($bound in 'Min', 'Max', 'Optimal') { $settings["${bound}PartitionEncode"] = $encode }
    $settings
}

function Get-HyperVGpuPChecks {
    param([System.Collections.IDictionary]$Config)
    $checks = [System.Collections.Generic.List[object]]::new()

    if (-not (Get-Module -ListAvailable Hyper-V)) {
        $checks.Add((New-CheckResult 'Hyper-V' Fail 'El módulo Hyper-V no está instalado. Actívalo en "Características de Windows".'))
        return $checks
    }
    if (-not (Test-IsAdmin)) {
        $checks.Add((New-CheckResult 'Hyper-V' Warn 'Sin permisos de administrador no se puede revisar Hyper-V ni las GPU particionables.'))
        return $checks
    }

    try {
        $vmHost = Get-VMHost -ErrorAction Stop
        $checks.Add((New-CheckResult 'Hyper-V' Ok "Activo. VMs en $($vmHost.VirtualMachinePath)"))
    }
    catch {
        $checks.Add((New-CheckResult 'Hyper-V' Fail 'Hyper-V no está activo. Ejecuta: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All, y reinicia.'))
        return $checks
    }

    $match = $Config['gpu']['match']
    $target = Get-HostGpu -Match $match | Select-Object -First 1
    $partitionable = @(Get-PartitionableGpuList)
    if (-not $partitionable) {
        $checks.Add((New-CheckResult 'GPU particionable' Fail 'Ninguna GPU admite GPU-P con el driver actual.'))
    }
    elseif ($target -and -not ($partitionable | Where-Object VendorId -eq $target.VendorId)) {
        $checks.Add((New-CheckResult 'GPU particionable' Fail "$($target.Name) no aparece como particionable. Actualiza el driver."))
    }
    else {
        $checks.Add((New-CheckResult 'GPU particionable' Ok "$($partitionable.Count) disponible(s): $(($partitionable.VendorId | ForEach-Object { "VEN_$_" }) -join ', ')"))
    }

    if ($partitionable.Count -gt 1 -and -not (Test-GpuInstancePathSupport)) {
        $checks.Add((New-CheckResult 'Selección de GPU' Warn ('Hay más de una GPU particionable y Windows 10 no permite elegir cuál recibe la VM. ' +
            'Si la VM recibe la integrada, desactívala en el Administrador de dispositivos antes de encender la VM (ver labs/001).')))
    }

    $switch = $Config['vm']['network']['switch']
    if ($switch -and -not (Get-VMSwitch -Name $switch -ErrorAction SilentlyContinue)) {
        $checks.Add((New-CheckResult 'Red' Warn "No existe el switch '$switch'; la VM se creará sin red."))
    }
    elseif ($switch) {
        $checks.Add((New-CheckResult 'Red' Ok "Switch '$switch'"))
    }
    $checks
}

function Set-HyperVGpuPVM {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )
    $vm = Get-VM -Name $Name -ErrorAction Stop
    if ($vm.State -ne 'Off') { throw "La VM '$Name' debe estar apagada para aplicar el perfil." }
    $c = $Config['vm']

    Write-Step "CPU: $($c['cpu']['count']) hilos, reserva $($c['cpu']['reservePercent']) %, peso $($c['cpu']['relativeWeight'])"
    # Migration compatibility would hide CPU features (AVX2 and later) that modern games require.
    Set-VMProcessor -VMName $Name -Count $c['cpu']['count'] -Reserve $c['cpu']['reservePercent'] `
        -RelativeWeight $c['cpu']['relativeWeight'] -ExposeVirtualizationExtensions $false -CompatibilityForMigrationEnabled $false
    if ($null -ne $c['cpu']['hwThreadsPerCore']) {
        try { Set-VMProcessor -VMName $Name -HwThreadCountPerCore $c['cpu']['hwThreadsPerCore'] -ErrorAction Stop }
        catch { Write-Warning "No se pudo ajustar la topología SMT (requiere configuración de VM 9.0 o superior): $_" }
    }

    Write-Step "Memoria fija: $($c['memoryGB']) GB"
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes ([int64]$c['memoryGB'] * 1GB)

    $vhdPath = (Get-VMHardDiskDrive -VMName $Name | Select-Object -First 1).Path
    if ($vhdPath -and $c['disk']['sizeGB']) { Expand-HyperVGpuPDisk -Path $vhdPath -SizeGB $c['disk']['sizeGB'] }

    # GPU-P supports neither checkpoints nor saved state; if the host shuts down, the guest shuts down cleanly.
    Set-VM -Name $Name -CheckpointType Disabled -AutomaticCheckpointsEnabled $false `
        -AutomaticStopAction ShutDown -AutomaticStartAction Nothing -GuestControlledCacheTypes $true `
        -LowMemoryMappedIoSpace ([int64]$c['mmio']['lowGB'] * 1GB) -HighMemoryMappedIoSpace ([int64]$c['mmio']['highGB'] * 1GB) `
        -Notes "Creada con GpuVM. Perfil: $($Config['name'])"

    $secureBoot = if ($c['secureBoot']) { 'On' } else { 'Off' }
    # Only what changed: Hyper-V refuses to touch the Secure Boot template once the vTPM is initialized,
    # which would make every later settings change fail.
    $firmware = Get-VMFirmware -VMName $Name
    $tpmOn = (Get-VMSecurity -VMName $Name).TpmEnabled
    if ([string]$firmware.SecureBoot -ne $secureBoot) { Set-VMFirmware -VMName $Name -EnableSecureBoot $secureBoot }
    if ($firmware.SecureBootTemplate -ne 'MicrosoftWindows' -and -not $tpmOn) { Set-VMFirmware -VMName $Name -SecureBootTemplate MicrosoftWindows }
    if ($c['tpm'] -and -not $tpmOn) {
        Set-VMKeyProtector -VMName $Name -NewLocalKeyProtector
        Enable-VMTPM -VMName $Name
    }

    $switch = $c['network']['switch']
    if ($switch -and (Get-VMSwitch -Name $switch -ErrorAction SilentlyContinue)) {
        Get-VMNetworkAdapter -VMName $Name | Connect-VMNetworkAdapter -SwitchName $switch
    }
    # The guest cannot pose as a DHCP server or router to other machines, nor change its MAC.
    Set-VMNetworkAdapter -VMName $Name -DhcpGuard On -RouterGuard On -MacAddressSpoofing Off

    $percent = $Config['gpu']['allocationPercent']
    Write-Step "GPU: partición al $percent %"
    Get-VMGpuPartitionAdapter -VMName $Name -ErrorAction SilentlyContinue | Remove-VMGpuPartitionAdapter
    $gpuParams = Get-GpuPartitionSettings -Percent $percent
    Add-VMGpuPartitionAdapter -VMName $Name @gpuParams
}

# Disks only grow: shrinking would cut the guest's partition. The guest extends C: itself on its next start
# (Expand-GuestSystemDisk), so the host never mounts a disk the guest has written to just for this.
function Expand-HyperVGpuPDisk {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$SizeGB
    )
    $vhd = Get-VHD -Path $Path
    $target = [uint64]$SizeGB * 1GB
    if ($target -lt $vhd.Size) {
        Write-Warning "El disco ya mide $([math]::Round($vhd.Size / 1GB)) GB; un disco no se puede reducir."
        return
    }
    if ($target -eq $vhd.Size) { return }
    if ($vhd.VhdType -eq 'Fixed') {
        $free = (Get-Volume -DriveLetter (Split-Path $Path -Qualifier).TrimEnd(':')).SizeRemaining
        $needed = $target - $vhd.Size
        if ($needed + 10GB -gt $free) {
            throw "No hay espacio para ampliar el disco: hacen falta $([math]::Ceiling($needed / 1GB)) GB y quedan $([math]::Floor($free / 1GB)) GB libres."
        }
    }
    Write-Step "Ampliando el disco a $SizeGB GB"
    Resize-VHD -Path $Path -SizeBytes $target
}

function Sync-HyperVGpuPDriver {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State
    )
    $vm = Get-VM -Name $Name -ErrorAction Stop
    if ($vm.State -ne 'Off') { throw "Apaga la VM '$Name' antes de sincronizar el driver." }
    $gpu = Get-HostGpu -Match $State['config']['gpu']['match'] | Select-Object -First 1
    if (-not $gpu) { throw "No se encontró la GPU '$($State['config']['gpu']['match'])' en el host." }

    Write-Step "Leyendo archivos del driver $($gpu.DriverVersion) de $($gpu.Name) (unos 30 s)"
    $fileSet = Get-GpuDriverFileSet -PnpDeviceId $gpu.PnpDeviceId
    $vhd = (Get-VMHardDiskDrive -VMName $Name | Select-Object -First 1).Path
    Invoke-WithMountedWindows -Path $vhd -ScriptBlock {
        param($root)
        $result = Copy-GpuDriverToWindows -FileSet $fileSet -WindowsRoot $root
        Write-Step "Driver copiado: $($result.Folders) carpetas del DriverStore y $($result.Files) archivos"
    }
    $gpu
}

Register-GpuVMBackend -Name 'hyperv-gpup' -Description 'Hyper-V con GPU Partitioning; la GPU se comparte con el host.' -Operations @{
    Test       = { param($Config) Get-HyperVGpuPChecks -Config $Config }

    New        = {
        param($Context)
        $name = $Context.Name
        $config = $Context.Config
        $vmDir = Join-Path $config['vm']['root'] $name
        $vhdPath = Join-Path $vmDir "Virtual Hard Disks\$name.vhdx"
        if (Test-Path -LiteralPath $vmDir) {
            throw "Ya existe la carpeta $vmDir de un intento anterior. Elige otro nombre o bórrala."
        }
        Initialize-GpuVMRoot -Path $config['vm']['root']

        $gpu = Get-HostGpu -Match $config['gpu']['match'] | Select-Object -First 1
        if (-not $gpu) { throw "No se encontró la GPU '$($config['gpu']['match'])' en el host." }
        Write-Step "Leyendo archivos del driver $($gpu.DriverVersion) de $($gpu.Name)"
        $fileSet = Get-GpuDriverFileSet -PnpDeviceId $gpu.PnpDeviceId

        New-Item -ItemType Directory -Path (Split-Path $vhdPath -Parent) -Force | Out-Null
        # If something fails halfway, no half-built VM or disk is left behind to get in the way of a retry.
        try {
        New-WindowsVhdx -Path $vhdPath -SizeGB $config['vm']['disk']['sizeGB'] -Type $config['vm']['disk']['type'] `
            -ImageFile $Context.ImageFile -ImageIndex $Context.ImageIndex -Customize {
            param($root)
            Write-Step 'Preparando instalación desatendida y scripts del invitado'
            $panther = Join-Path $root 'Windows\Panther'
            New-Item -ItemType Directory -Path $panther -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $panther 'unattend.xml') -Value $Context.UnattendXml -Encoding utf8

            $guestDir = Join-Path $root 'GpuVM'
            New-Item -ItemType Directory -Path $guestDir -Force | Out-Null
            Copy-Item -Path (Join-Path (Get-RepoPath 'guest') '*') -Destination $guestDir -Recurse -Force
            Write-JsonFile -Path (Join-Path $guestDir 'guest-config.json') -Data $config['guest']
            foreach ($file in @($Context.GuestFiles)) {
                if (-not $file) { continue }
                if ($file.Sha256 -and (Get-FileSha256 $file.Source) -ne $file.Sha256) {
                    throw "El archivo $($file.Source) cambió desde que se verificó; no se copia a la VM."
                }
                $target = Join-Path $guestDir $file.Destination
                New-Item -ItemType Directory -Path $target -Force | Out-Null
                Copy-Item -LiteralPath $file.Source -Destination $target -Force
            }
            if ($Context.GuestJson) {
                foreach ($relative in $Context.GuestJson.Keys) {
                    Write-JsonFile -Path (Join-Path $guestDir $relative) -Data $Context.GuestJson[$relative]
                }
            }

            Write-Step 'Copiando el driver de la GPU al invitado'
            $result = Copy-GpuDriverToWindows -FileSet $fileSet -WindowsRoot $root
            Write-Step "Driver copiado: $($result.Folders) carpetas del DriverStore y $($result.Files) archivos"
        }

        Write-Step "Registrando la VM '$name' en Hyper-V"
        $switch = $config['vm']['network']['switch']
        $vmParams = @{
            Name               = $name
            Generation         = 2
            MemoryStartupBytes = [int64]$config['vm']['memoryGB'] * 1GB
            VHDPath            = $vhdPath
            Path               = $config['vm']['root']
        }
        if ($switch -and (Get-VMSwitch -Name $switch -ErrorAction SilentlyContinue)) { $vmParams['SwitchName'] = $switch }
        New-VM @vmParams | Out-Null
        Set-HyperVGpuPVM -Name $name -Config $config
        }
        catch {
            Write-Step 'La creación falló; limpiando lo que se alcanzó a crear'
            if (Get-VM -Name $name -ErrorAction SilentlyContinue) { Remove-VM -Name $name -Force -ErrorAction SilentlyContinue }
            if ((Get-VHD -Path $vhdPath -ErrorAction SilentlyContinue).Attached) { Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $vmDir -Recurse -Force -ErrorAction SilentlyContinue
            throw
        }

        [ordered]@{
            name        = $name
            backend     = 'hyperv-gpup'
            profile     = $config['name']
            config      = $config
            vmDir       = $vmDir
            vhdPath     = $vhdPath
            gpu         = [ordered]@{
                name          = $gpu.Name
                pnpDeviceId   = $gpu.PnpDeviceId
                driverVersion = $gpu.DriverVersion
                syncedAt      = (Get-Date).ToString('o')
            }
            createdAt   = (Get-Date).ToString('o')
            toolVersion = $script:ToolVersion
            statePath   = Join-Path $vmDir 'gpuvm.json'
        }
    }

    Apply      = { param($Name, $Config) Set-HyperVGpuPVM -Name $Name -Config $Config }

    SyncDriver = { param($Name, $State) Sync-HyperVGpuPDriver -Name $Name -State $State }

    Remove     = {
        param($Name, $State, $DeleteDisk)
        # Checked before removing anything: only the VM's own folder inside the installed GpuVM root is deleted,
        # never any other path. A VM kept elsewhere is refused whole, instead of being removed with its disk left over.
        $dir = $null
        if ($DeleteDisk -and $State['vmDir'] -and (Test-Path -LiteralPath $State['vmDir'])) {
            $root = Get-GpuVMDefaultRoot
            $dir = [IO.Path]::GetFullPath($State['vmDir']).TrimEnd('\')
            if ($dir -ne (Join-Path $root $Name)) {
                throw "No se borra la VM con su disco: $dir no es la carpeta de la VM dentro de $root. Elimínala conservando el disco."
            }
        }
        $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
        if ($vm) {
            if ($vm.State -ne 'Off') { Stop-VM -Name $Name -TurnOff -Force }
            Remove-VM -Name $Name -Force
        }
        if ($dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}
