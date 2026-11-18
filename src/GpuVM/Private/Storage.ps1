# Disks and ISOs: the folder where GpuVM keeps VMs, growing the guest's C: and the library of used ISOs.

# Where GpuVM keeps VM folders. Read from the installed base profile, never from a VM's own state file,
# so a tampered gpuvm.json cannot point deletions somewhere else.
function Get-GpuVMDefaultRoot {
    $base = Read-JsonFile (Join-Path (Get-ProfileDirectory) 'base.json')
    [IO.Path]::GetFullPath($base['vm']['root']).TrimEnd('\')
}

function Get-DriveFreeGB {
    param([Parameter(Mandatory)][string]$Path)
    [math]::Floor(([IO.DriveInfo]::new((Split-Path $Path -Qualifier))).AvailableFreeSpace / 1GB)
}

# Space the host keeps for itself on a drive with VM disks (Windows, updates, the page file).
$script:DiskMarginGB = 20
$script:DiskCache = $null

# Every VM disk on the host, by drive: its full size, what its file takes today and how much it can still grow
# (a dynamic disk grows up to its size as the guest writes; a fixed one already takes it all). Read every 30 s at
# most (Get-VHD costs ~0.1 s per disk and the overview is refreshed every few seconds).
function Get-VMDiskUsage {
    if ($script:DiskCache -and ((Get-Date) - $script:DiskCache.At).TotalSeconds -lt 30) { return $script:DiskCache.Disks }
    $disks = foreach ($vm in @(Get-VM -ErrorAction SilentlyContinue)) {
        foreach ($drive in @(Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction SilentlyContinue)) {
            if (-not $drive.Path) { continue }
            $vhd = Get-VHD -Path $drive.Path -ErrorAction SilentlyContinue
            if (-not $vhd) { continue }
            [pscustomobject]@{
                VM = $vm.Name; Path = $drive.Path; Drive = (Split-Path $drive.Path -Qualifier).ToUpperInvariant()
                SizeGB = [math]::Round($vhd.Size / 1GB, 1); FileGB = [math]::Round($vhd.FileSize / 1GB, 1)
                # A disposable machine is promised only its fixed reserve (it is shut down before the drive fills up).
                GrowthGB = if (Test-GpuVMDisposableByName -Name $vm.Name) { [math]::Max(0, [math]::Round($script:DisposableReserveGB - $vhd.FileSize / 1GB, 1)) }
                    else { [math]::Max(0, [math]::Round(($vhd.Size - $vhd.FileSize) / 1GB, 1)) }
                Type = [string]$vhd.VhdType
            }
        }
    }
    $script:DiskCache = [pscustomobject]@{ At = Get-Date; Disks = @($disks) }
    @($disks)
}

# What a disk on $Root's drive can really have: the drive's free space, minus what the other VMs' disks there can
# still grow into (space they are promised), minus the host's margin. -VMName leaves that VM's own disk out of the
# promised space and returns how far its disk can grow (its size + its own unwritten part + what is left).
function Get-GpuVMDiskBudget {
    param([Parameter(Mandatory)][string]$Root, [string]$VMName)
    $drive = (Split-Path $Root -Qualifier).ToUpperInvariant()
    $free = [math]::Round(([IO.DriveInfo]::new($drive)).AvailableFreeSpace / 1GB, 1)
    $all = @(Get-VMDiskUsage | Where-Object Drive -eq $drive)
    $others = @($all | Where-Object { $_.VM -ne $VMName })
    $own = @($all | Where-Object { $VMName -and $_.VM -eq $VMName } | Select-Object -First 1)
    $promised = [math]::Round(($others | Measure-Object GrowthGB -Sum).Sum, 1)
    $ownGrowth = if ($own) { $own[0].GrowthGB } else { 0 }
    # What a new or bigger disk can take without being able to fill the drive when every disk is full.
    $available = [math]::Max(0, [math]::Floor($free - $promised - $ownGrowth - $script:DiskMarginGB))
    [ordered]@{
        drive = $drive; freeGB = $free; promisedGB = $promised; marginGB = $script:DiskMarginGB
        availableGB = $available
        sizeGB = if ($own) { $own[0].SizeGB } else { $null }; usedGB = if ($own) { $own[0].FileGB } else { $null }
        maxGB = if ($own) { [math]::Floor($own[0].SizeGB + $available) } else { $available }
        others = @($others | Group-Object VM | ForEach-Object { [ordered]@{ vm = $_.Name; promisedGB = [math]::Round(($_.Group | Measure-Object GrowthGB -Sum).Sum, 1) } } | Where-Object { $_.promisedGB -gt 0 })
    }
}

# Grows the guest's C: into the free space at the end of its disk (after Resize-VHD), from inside the guest.
function Expand-GuestSystemDisk {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    $grown = Invoke-Guest -Name $Name -Credential $Credential -ScriptBlock {
        $partition = Get-Partition -DriveLetter C
        $max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
        if ($max - $partition.Size -lt 1GB) { return 0 }
        Resize-Partition -DriveLetter C -Size $max
        [math]::Round($max / 1GB)
    }
    $sizeGB = [int]$grown
    if ($sizeGB -gt 0) { Write-Step "Disco C: de la VM ampliado a $sizeGB GB" }
}

function Get-IsoLibraryPath { Get-DataPath 'isos.json' }

function Read-IsoLibrary {
    $path = Get-IsoLibraryPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    @((Read-JsonFile $path)['isos'] | Where-Object { $_ })
}

function Save-IsoLibrary {
    param([object[]]$Entries)
    Write-JsonFile -Path (Get-IsoLibraryPath) -Data ([ordered]@{ isos = @($Entries) })
}

# Remembers an ISO (and which VM used it) so the "Create machine" wizard offers it again.
# A renamed VM keeps its place in the "used by" of each ISO.
function Rename-GpuVMIsoUse {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$NewName)
    $entries = @(Read-IsoLibrary)
    $changed = $false
    foreach ($entry in $entries) {
        $used = @($entry['usedBy'] | Where-Object { $_ })
        if ($used -notcontains $Name) { continue }
        $entry['usedBy'] = @($used | ForEach-Object { if ($_ -eq $Name) { $NewName } else { $_ } } | Select-Object -Unique)
        $changed = $true
    }
    if ($changed) { Save-IsoLibrary $entries }
}

# A VM name must be free in Hyper-V and, with -Root, as a folder there (one left by a failed attempt also takes it).
# -Except skips the VM being renamed, so a name that only changes case is not taken by itself.
function Assert-GpuVMNameFree {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Root,
        [guid]$Except = [guid]::Empty
    )
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $Except }) { throw "Ya existe una VM llamada '$Name'." }
    if ($Root) {
        $dir = Join-Path $Root $Name
        if (Test-Path -LiteralPath $dir) { throw "Ya existe la carpeta $dir. Elige otro nombre o bórrala." }
    }
}

function Register-GpuVMIsoUse {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$VMName
    )
    $full = [IO.Path]::GetFullPath($Path)
    $entries = [System.Collections.Generic.List[object]]::new()
    $entry = $null
    foreach ($e in Read-IsoLibrary) {
        if ($e['path'] -eq $full) { $entry = $e } else { $entries.Add($e) }
    }
    if (-not $entry) { $entry = [ordered]@{ path = $full; addedAt = (Get-Date).ToString('o'); lastUsed = $null; usedBy = @() } }
    if ($VMName) {
        $entry['lastUsed'] = (Get-Date).ToString('o')
        $entry['usedBy'] = @(@($entry['usedBy']) + $VMName | Where-Object { $_ } | Select-Object -Unique)
    }
    $entries.Insert(0, $entry)
    Save-IsoLibrary $entries
}
