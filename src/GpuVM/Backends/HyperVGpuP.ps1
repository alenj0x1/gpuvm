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
        $checks.Add((New-CheckResult 'Hyper-V' Fail 'The Hyper-V module isn''t installed. Turn it on in "Windows Features".'))
        return $checks
    }
    if (-not (Test-IsAdmin)) {
        $checks.Add((New-CheckResult 'Hyper-V' Warn 'Without administrator rights, Hyper-V and the partitionable GPUs can''t be checked.'))
        return $checks
    }

    try {
        $vmHost = Get-VMHost -ErrorAction Stop
        $checks.Add((New-CheckResult 'Hyper-V' Ok "On. VMs in $($vmHost.VirtualMachinePath)"))
    }
    catch {
        $checks.Add((New-CheckResult 'Hyper-V' Fail 'Hyper-V isn''t on. Run: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All, and restart.'))
        return $checks
    }

    $match = $Config['gpu']['match']
    $target = Get-HostGpu -Match $match | Select-Object -First 1
    $partitionable = @(Get-PartitionableGpuList)
    if (-not $partitionable) {
        $checks.Add((New-CheckResult 'Partitionable GPU' Fail 'No GPU supports GPU-P with the current driver.'))
    }
    elseif ($target -and -not ($partitionable | Where-Object VendorId -eq $target.VendorId)) {
        $checks.Add((New-CheckResult 'Partitionable GPU' Fail "$($target.Name) doesn't show up as partitionable. Update the driver."))
    }
    else {
        $checks.Add((New-CheckResult 'Partitionable GPU' Ok "$($partitionable.Count) available: $(($partitionable.VendorId | ForEach-Object { "VEN_$_" }) -join ', ')"))
    }

    if ($partitionable.Count -gt 1 -and -not (Test-GpuInstancePathSupport)) {
        $checks.Add((New-CheckResult 'GPU choice' Warn ('There''s more than one partitionable GPU and Windows 10 can''t choose which one the VM gets. ' +
            'If the VM gets the integrated one, disable it in Device Manager before turning on the VM (see labs/001).')))
    }

    # The new disk must fit once every VM disk on the drive is full (dynamic disks grow up to their size).
    $sizeGB = [int]$Config['vm']['disk']['sizeGB']
    if ($sizeGB -and $Config['vm']['root']) {
        $budget = Get-GpuVMDiskBudget -Root $Config['vm']['root']
        if ($sizeGB -gt $budget['availableGB']) {
            $checks.Add((New-CheckResult 'Disk' Fail ("A $sizeGB GB disk doesn't fit on $($budget['drive']): $([math]::Floor($budget['freeGB'])) GB are free and " +
                "$([math]::Ceiling($budget['promisedGB'])) GB are already set aside for other machines' disks. Choose $($budget['availableGB']) GB at most.")))
        }
        else {
            $checks.Add((New-CheckResult 'Disk' Ok "$sizeGB GB on $($budget['drive']); $($budget['availableGB'] - $sizeGB) GB left for more machines"))
        }
    }

    $switch = $Config['vm']['network']['switch']
    if ($switch -and -not (Get-VMSwitch -Name $switch -ErrorAction SilentlyContinue)) {
        $checks.Add((New-CheckResult 'Network' Warn "The switch '$switch' doesn't exist; the VM will be created without a network."))
    }
    elseif ($switch) {
        $checks.Add((New-CheckResult 'Network' Ok "Switch '$switch'"))
    }
    $checks
}

function Set-HyperVGpuPVM {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )
    $vm = Get-VM -Name $Name -ErrorAction Stop
    if ($vm.State -ne 'Off') { throw "The VM '$Name' must be off to apply the profile." }
    $c = $Config['vm']

    Write-Step "CPU: $($c['cpu']['count']) threads, $($c['cpu']['reservePercent']) % reserved, weight $($c['cpu']['relativeWeight'])"
    # Migration compatibility would hide CPU features (AVX2 and later) that modern games require.
    Set-VMProcessor -VMName $Name -Count $c['cpu']['count'] -Reserve $c['cpu']['reservePercent'] `
        -RelativeWeight $c['cpu']['relativeWeight'] -ExposeVirtualizationExtensions $false -CompatibilityForMigrationEnabled $false
    if ($null -ne $c['cpu']['hwThreadsPerCore']) {
        try { Set-VMProcessor -VMName $Name -HwThreadCountPerCore $c['cpu']['hwThreadsPerCore'] -ErrorAction Stop }
        catch { Write-Warning "Couldn't set the SMT topology (needs VM configuration 9.0 or later): $_" }
    }

    Write-Step "Fixed memory: $($c['memoryGB']) GB"
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes ([int64]$c['memoryGB'] * 1GB)

    $vhdPath = (Get-VMHardDiskDrive -VMName $Name | Select-Object -First 1).Path
    if ($vhdPath -and $c['disk']['sizeGB']) { Expand-HyperVGpuPDisk -Path $vhdPath -SizeGB $c['disk']['sizeGB'] }

    # GPU-P supports neither checkpoints nor saved state; if the host shuts down, the guest shuts down cleanly.
    Set-VM -Name $Name -CheckpointType Disabled -AutomaticCheckpointsEnabled $false `
        -AutomaticStopAction ShutDown -AutomaticStartAction Nothing -GuestControlledCacheTypes $true `
        -LowMemoryMappedIoSpace ([int64]$c['mmio']['lowGB'] * 1GB) -HighMemoryMappedIoSpace ([int64]$c['mmio']['highGB'] * 1GB) `
        -Notes "Created with GpuVM. Profile: $($Config['name'])"

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
    Update-GpuVMNetworkIsolation -Name $Name -State @{ config = $Config }

    $percent = $Config['gpu']['allocationPercent']
    Write-Step "GPU: $percent % partition"
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
        Write-Warning "The disk is already $([math]::Round($vhd.Size / 1GB)) GB; a disk can't be shrunk."
        return
    }
    if ($target -eq $vhd.Size) { return }
    if ($vhd.VhdType -eq 'Differencing') { throw 'The disk of a machine created from a template is the same size as the template and can''t be enlarged.' }
    # Never more than the drive can really hold once every VM disk on it is full (the app shows the same limit).
    $script:DiskCache = $null
    $owner = Get-VMDiskUsage | Where-Object { $_.Path -eq $Path } | Select-Object -First 1
    $budget = Get-GpuVMDiskBudget -Root $Path -VMName $(if ($owner) { $owner.VM })
    if ($SizeGB -gt $budget['maxGB']) {
        throw "There's no room for a $SizeGB GB disk: $($budget['drive']) has $([math]::Floor($budget['freeGB'])) GB free and $([math]::Ceiling($budget['promisedGB'])) GB are already set aside for other machines' disks. $($budget['maxGB']) GB at most."
    }
    if ($vhd.VhdType -eq 'Fixed') {
        $free = (Get-Volume -DriveLetter (Split-Path $Path -Qualifier).TrimEnd(':')).SizeRemaining
        $needed = $target - $vhd.Size
        if ($needed + 10GB -gt $free) {
            throw "There's no room to enlarge the disk: $([math]::Ceiling($needed / 1GB)) GB are needed and $([math]::Floor($free / 1GB)) GB are free."
        }
    }
    Write-Step "Enlarging the disk to $SizeGB GB"
    Resize-VHD -Path $Path -SizeBytes $target
}

function Sync-HyperVGpuPDriver {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State
    )
    $vm = Get-VM -Name $Name -ErrorAction Stop
    if ($vm.State -ne 'Off') { throw "Turn off the VM '$Name' before syncing the driver." }
    $gpu = Get-HostGpu -Match $State['config']['gpu']['match'] | Select-Object -First 1
    if (-not $gpu) { throw "The GPU '$($State['config']['gpu']['match'])' wasn't found on the host." }

    Write-Step "Reading the files of driver $($gpu.DriverVersion) for $($gpu.Name)"
    $fileSet = Get-GpuDriverFileSet -PnpDeviceId $gpu.PnpDeviceId -DriverVersion $gpu.DriverVersion
    $vhd = (Get-VMHardDiskDrive -VMName $Name | Select-Object -First 1).Path
    Invoke-WithMountedWindows -Path $vhd -ScriptBlock {
        param($root)
        $result = Copy-GpuDriverToWindows -FileSet $fileSet -WindowsRoot $root
        Write-Step "Driver copied: $($result.Folders) DriverStore folders and $($result.Files) files"
    }
    $gpu
}

# Where a path inside the VM's folder ends up once the folder takes the new name; $null for a path outside it
# (a shared disk, a template's parent disk), which stays where it is. A disk named after the VM takes the new name.
function Get-RenamedVMPath {
    param(
        [string]$Path,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$NewName
    )
    if (-not $Path) { return $null }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -ne $From -and -not $full.StartsWith("$From\", [StringComparison]::OrdinalIgnoreCase)) { return $null }
    $moved = $To + $full.Substring($From.Length)
    $extension = [IO.Path]::GetExtension($moved)
    if ($extension -in '.vhdx', '.vhd' -and [IO.Path]::GetFileNameWithoutExtension($moved) -eq $Name) {
        $moved = Join-Path (Split-Path $moved -Parent) "$NewName$extension"
    }
    $moved
}

# Moves a file or folder (same volume: a rename, nothing is copied), creating the destination's folder if needed.
function Move-GpuVMItem {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Destination)
    $parent = Split-Path $Destination -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (Test-Path -LiteralPath $Path -PathType Container) { [IO.Directory]::Move($Path, $Destination) }
    else { [IO.File]::Move($Path, $Destination) }
}

# Moves what is left in the old folder into the new one, merging folders Hyper-V already created there.
# Each move is recorded in $Done so it can be undone; a file that already exists at the destination stops it.
function Move-GpuVMFolderContent {
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[hashtable]]$Done
    )
    foreach ($item in @(Get-ChildItem -LiteralPath $From -Force)) {
        $target = Join-Path $To $item.Name
        if (-not (Test-Path -LiteralPath $target)) {
            Move-GpuVMItem -Path $item.FullName -Destination $target
            $Done.Add(@{ step = 'item'; from = $item.FullName; to = $target })
        }
        elseif ($item.PSIsContainer -and (Test-Path -LiteralPath $target -PathType Container)) {
            Move-GpuVMFolderContent -From $item.FullName -To $target -Done $Done
        }
        else { throw "$target already exists." }
    }
}

# Undoes the recorded steps of a rename, newest first. Returns what could not be undone.
function Undo-HyperVGpuPRename {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[hashtable]]$Done,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$NewName
    )
    $problems = [System.Collections.Generic.List[string]]::new()
    for ($i = $Done.Count - 1; $i -ge 0; $i--) {
        $step = $Done[$i]
        try {
            switch ($step['step']) {
                'name' { Rename-VM -Name $NewName -NewName $Name -ErrorAction Stop }
                'folder' {
                    $files = @(Get-ChildItem -LiteralPath $step['path'] -Recurse -Force -File -ErrorAction SilentlyContinue)
                    if (-not $files.Count) { Remove-Item -LiteralPath $step['path'] -Recurse -Force }
                }
                'storage' { $back = $step['back']; Move-VMStorage -VMName $NewName @back -ErrorAction Stop }
                'item' { Move-GpuVMItem -Path $step['to'] -Destination $step['from'] }
                'disk' {
                    $d = $step['drive']
                    Set-VMHardDiskDrive -VMName $NewName -ControllerType $d.ControllerType -ControllerNumber $d.ControllerNumber `
                        -ControllerLocation $d.ControllerLocation -Path $step['path'] -ErrorAction Stop
                }
                'state' { Set-Content -LiteralPath $step['path'] -Value $step['text'] -NoNewline -Encoding utf8 }
            }
        }
        catch { $problems.Add($_.Exception.Message) }
    }
    , $problems
}

# Renames a stopped VM and moves what lives in its folder (configuration, disk, gpuvm.json) to a folder with the new
# name. The VM is never unregistered from Hyper-V: its configuration moves with Move-VMStorage and its disk is renamed
# in place (same volume, nothing copied) and attached again at the new path. Each step is recorded; if one fails, the
# ones before it are undone newest first and the error is thrown. A name that only changes case keeps the folder.
function Rename-HyperVGpuPVM {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$NewName,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State
    )
    $oldDir = [IO.Path]::GetFullPath($State['vmDir']).TrimEnd('\')
    # Only a folder named after the VM takes the new name; a VM kept in a folder of another name stays there.
    $moveFolder = $NewName -ne $Name -and (Split-Path $oldDir -Leaf) -eq $Name
    $newDir = if ($moveFolder) { Join-Path (Split-Path $oldDir -Parent) $NewName } else { $oldDir }
    $paths = @{ From = $oldDir; To = $newDir; Name = $Name; NewName = $NewName }
    $vm = Get-VM -Name $Name -ErrorAction Stop
    $done = [System.Collections.Generic.List[hashtable]]::new()
    try {
        Write-Step "Renaming it in Hyper-V to '$NewName'"
        Rename-VM -Name $Name -NewName $NewName -ErrorAction Stop
        $done.Add(@{ step = 'name' })

        if ($moveFolder) {
            if (Test-Path -LiteralPath $newDir) { throw "The folder $newDir already exists. Choose another name or delete it." }
            New-Item -ItemType Directory -Path $newDir -Force | Out-Null
            $done.Add(@{ step = 'folder'; path = $newDir })

            Write-Step 'Moving the VM''s settings to its new folder'
            $move = @{}
            $back = @{}
            foreach ($pair in @(('VirtualMachinePath', $vm.ConfigurationLocation), ('SnapshotFilePath', $vm.SnapshotFileLocation),
                    ('SmartPagingFilePath', $vm.SmartPagingFilePath))) {
                $target = Get-RenamedVMPath -Path $pair[1] @paths
                if ($target) { $move[$pair[0]] = $target; $back[$pair[0]] = $pair[1] }
            }
            if ($move.Count) {
                Move-VMStorage -VMName $NewName @move -ErrorAction Stop
                $done.Add(@{ step = 'storage'; back = $back })
            }

            Write-Step 'Renaming the disk'
            foreach ($drive in @(Get-VMHardDiskDrive -VMName $NewName)) {
                $target = Get-RenamedVMPath -Path $drive.Path @paths
                if (-not $target) { continue }
                Move-GpuVMItem -Path $drive.Path -Destination $target
                $done.Add(@{ step = 'item'; from = $drive.Path; to = $target })
                Set-VMHardDiskDrive -VMName $NewName -ControllerType $drive.ControllerType -ControllerNumber $drive.ControllerNumber `
                    -ControllerLocation $drive.ControllerLocation -Path $target -ErrorAction Stop
                $done.Add(@{ step = 'disk'; drive = $drive; path = $drive.Path })
            }
            Move-GpuVMFolderContent -From $oldDir -To $newDir -Done $done
        }

        $renamed = Merge-Hashtable -Base $State
        $renamed['name'] = $NewName
        $renamed['vmDir'] = $newDir
        foreach ($key in 'vhdPath', 'statePath') {
            $target = Get-RenamedVMPath -Path $State[$key] @paths
            if ($target) { $renamed[$key] = $target }
        }
        # Restore points are differencing disks that name their parent by path: point them at the new folder.
        if ($moveFolder) { Repair-GpuVMDiskChain -State $renamed -From $oldDir -To $newDir -Name $Name -NewName $NewName }
        $done.Add(@{ step = 'state'; path = $renamed['statePath']; text = (Get-Content -Raw -LiteralPath $renamed['statePath']) })
        Save-GpuVMState $renamed
    }
    catch {
        $failure = $_.Exception.Message
        Write-Step 'Couldn''t rename it; putting the VM back as it was'
        $problems = Undo-HyperVGpuPRename -Done $done -Name $Name -NewName $NewName
        if ($problems.Count) {
            throw "Couldn't rename '$Name': $failure Nor could everything be put back as it was: $($problems -join ' ') Check the VM in Hyper-V Manager."
        }
        throw "Couldn't rename '$Name': $failure The VM was left as it was."
    }

    # Only empty folders are left in the old one; a leftover never undoes a rename that worked.
    if ($moveFolder -and -not @(Get-ChildItem -LiteralPath $oldDir -Recurse -Force -File -ErrorAction SilentlyContinue).Count) {
        Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $renamed
}

Register-GpuVMBackend -Name 'hyperv-gpup'-Description 'Hyper-V with GPU Partitioning; the GPU is shared with the host.' -Operations @{
    Test       = { param($Config) Get-HyperVGpuPChecks -Config $Config }

    New        = {
        param($Context)
        $name = $Context.Name
        $config = $Context.Config
        $vmDir = Join-Path $config['vm']['root'] $name
        $vhdPath = Join-Path $vmDir "Virtual Hard Disks\$name.vhdx"
        if (Test-Path -LiteralPath $vmDir) {
            throw "The folder $vmDir already exists from an earlier attempt. Choose another name or delete it."
        }
        Initialize-GpuVMRoot -Path $config['vm']['root']

        $gpu = Get-HostGpu -Match $config['gpu']['match'] | Select-Object -First 1
        if (-not $gpu) { throw "The GPU '$($config['gpu']['match'])' wasn't found on the host." }
        Write-Step "Reading the files of driver $($gpu.DriverVersion) for $($gpu.Name)"
        $fileSet = Get-GpuDriverFileSet -PnpDeviceId $gpu.PnpDeviceId -DriverVersion $gpu.DriverVersion

        New-Item -ItemType Directory -Path (Split-Path $vhdPath -Parent) -Force | Out-Null
        # If something fails halfway, no half-built VM or disk is left behind to get in the way of a retry.
        try {
        New-WindowsVhdx -Path $vhdPath -SizeGB $config['vm']['disk']['sizeGB'] -Type $config['vm']['disk']['type'] `
            -ImageFile $Context.ImageFile -ImageIndex $Context.ImageIndex -Edition $Context.Edition -Language $Context.Language -Customize {
            param($root)
            Write-Step 'Preparing the unattended install and the guest scripts'
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
                    throw "The file $($file.Source) changed since it was verified; it won't be copied to the VM."
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

            Write-Step 'Copying the GPU driver to the guest'
            $result = Copy-GpuDriverToWindows -FileSet $fileSet -WindowsRoot $root
            Write-Step "Driver copied: $($result.Folders) DriverStore folders and $($result.Files) files"
        }

        Write-Step "Registering the VM '$name' in Hyper-V"
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
            Write-Step 'Creation failed; cleaning up what was already made'
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

    # A VM on top of a template: a differencing disk (only what changes is written), with Sunshine's identity reset
    # on it before the first boot. Disk folder, cleanup on failure and returned state work as in New.
    Clone      = {
        param($Context)
        $name = $Context.Name
        $config = $Context.Config
        $template = $Context.Template
        $vmDir = Join-Path $config['vm']['root'] $name
        $vhdPath = Join-Path $vmDir "Virtual Hard Disks\$name.vhdx"
        if (Test-Path -LiteralPath $vmDir) {
            throw "The folder $vmDir already exists from an earlier attempt. Choose another name or delete it."
        }
        Initialize-GpuVMRoot -Path $config['vm']['root']
        New-Item -ItemType Directory -Path (Split-Path $vhdPath -Parent) -Force | Out-Null
        try {
            Write-Step "Creating the disk on top of the template '$($template['name'])'"
            New-VHD -Path $vhdPath -ParentPath $template['vhdPath'] -Differencing | Out-Null
            Invoke-WithMountedWindows -Path $vhdPath -ScriptBlock {
                param($root)
                Write-Step 'Giving the copy its own streaming identity'
                Reset-ClonedGuestIdentity -WindowsRoot $root
            }

            Write-Step "Registering the VM '$name' in Hyper-V"
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
            Write-Step 'Creation failed; cleaning up what was already made'
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
            # The driver inside is the template's; if the host's changed since, it is updated on the first open.
            gpu         = $template['gpu']
            template    = $template['name']
            createdAt   = (Get-Date).ToString('o')
            toolVersion = $script:ToolVersion
            statePath   = Join-Path $vmDir 'gpuvm.json'
        }
    }

    Apply      = { param($Name, $Config) Set-HyperVGpuPVM -Name $Name -Config $Config }

    SyncDriver = { param($Name, $State) Sync-HyperVGpuPDriver -Name $Name -State $State }

    Rename     = { param($Name, $NewName, $State) Rename-HyperVGpuPVM -Name $Name -NewName $NewName -State $State }

    Remove     = {
        param($Name, $State, $DeleteDisk)
        # Checked before removing anything: only the VM's own folder inside the installed GpuVM root is deleted,
        # never any other path. A VM kept elsewhere is refused whole, instead of being removed with its disk left over.
        $dir = $null
        if ($DeleteDisk -and $State['vmDir'] -and (Test-Path -LiteralPath $State['vmDir'])) {
            $root = Get-GpuVMDefaultRoot
            $dir = [IO.Path]::GetFullPath($State['vmDir']).TrimEnd('\')
            if ($dir -ne (Join-Path $root $Name)) {
                throw "The VM won't be deleted with its disk: $dir isn't the VM's folder inside $root. Delete it keeping the disk."
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
