$script:GptTypes = @{
    Efi   = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    Msr   = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
    Basic = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
}

# The Dism module does not load reliably in PowerShell 7; it is used through the compatibility layer.
function Import-DismCompat {
    if (-not (Get-Command Get-WindowsImage -ErrorAction SilentlyContinue)) {
        Import-Module Dism -UseWindowsPowerShell -WarningAction SilentlyContinue -ErrorAction Stop
    }
}

function Mount-WindowsIso {
    param([Parameter(Mandatory)][string]$IsoPath)
    $full = (Resolve-Path -LiteralPath $IsoPath).Path
    $image = Get-DiskImage -ImagePath $full
    $wasAttached = [bool]$image.Attached
    if (-not $wasAttached) { $image = Mount-DiskImage -ImagePath $full -PassThru }
    $letter = ($image | Get-Volume).DriveLetter
    $imageFile = @('install.wim', 'install.esd') |
        ForEach-Object { "${letter}:\sources\$_" } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
    if (-not $imageFile) {
        if (-not $wasAttached) { Dismount-DiskImage -ImagePath $full | Out-Null }
        throw "El ISO no contiene sources\install.wim ni install.esd: $full"
    }
    [pscustomobject]@{ IsoPath = $full; ImageFile = $imageFile; WasAttached = $wasAttached }
}

function Get-WindowsEditionList {
    param([Parameter(Mandatory)][string]$ImageFile)
    Import-DismCompat
    Get-WindowsImage -ImagePath $ImageFile | ForEach-Object {
        [pscustomobject]@{ Index = [int]$_.ImageIndex; Name = [string]$_.ImageName }
    }
}

# "Pro" picks "Windows 11 Pro" and not "Windows 11 Pro N"; a full name also works.
function Select-WindowsEdition {
    param(
        [Parameter(Mandatory)]$Editions,
        [Parameter(Mandatory)][string]$Edition
    )
    $match = $Editions | Where-Object Name -eq $Edition | Select-Object -First 1
    if (-not $match) {
        $match = $Editions | Where-Object { $_.Name -match " $([regex]::Escape($Edition))$" } | Select-Object -First 1
    }
    if (-not $match) {
        throw "No hay edición '$Edition' en la imagen. Disponibles: $(($Editions.Name) -join ', ')"
    }
    $match
}

function Get-WindowsImageLanguage {
    param([string]$ImageFile, [int]$Index)
    Import-DismCompat
    $info = Get-WindowsImage -ImagePath $ImageFile -Index $Index
    $languages = @($info.Languages)
    if ($languages.Count -eq 0) { return 'en-US' }
    $default = [int]$info.DefaultLanguageIndex
    if ($default -ge $languages.Count) { $default = 0 }
    [string]$languages[$default]
}

# Creates a VM's VHDX with the chosen edition of Windows and boot set up. Windows comes from the edition's base disk
# (Bases.ps1), applied from the ISO only the first time. $Customize receives the root of the disk's Windows
# (a folder, the disk has no drive letter) to copy files before dismounting.
function New-WindowsVhdx {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$SizeGB,
        [ValidateSet('Dynamic', 'Fixed')][string]$Type = 'Dynamic',
        [Parameter(Mandatory)][string]$ImageFile,
        [Parameter(Mandatory)][int]$ImageIndex,
        [string]$Edition,
        [string]$Language,
        [scriptblock]$Customize
    )
    if (Test-Path -LiteralPath $Path) { throw "Ya existe el disco $Path." }
    $base = Get-WindowsBaseDisk -ImageFile $ImageFile -ImageIndex $ImageIndex -Edition $Edition -Language $Language
    if ($Type -eq 'Fixed') {
        # Hyper-V writes the whole fixed disk; it can't be run at low priority.
        Write-Step "Creando disco fijo de $SizeGB GB (escribe el disco entero; tarda unos minutos)"
        Convert-VHD -Path $base -DestinationPath $Path -VHDType Fixed -ErrorAction Stop
        (Get-Item -LiteralPath $Path).IsReadOnly = $false
    }
    else {
        Write-Step 'Copiando Windows al disco de la máquina'
        $copy = Copy-PacedFile -Source $base -Destination $Path
        Write-Step ('Windows copiado ({0:N0} s, {1:N0} MB/s, {2} pausas para no frenar el equipo)' -f $copy[0], $copy[1], $copy[2])
    }
    Resize-VHD -Path $Path -SizeBytes ([uint64]$SizeGB * 1GB)
    Invoke-WithMountedWindows -Path $Path -ExpandPartition -ScriptBlock {
        param($root)
        if ($Customize) { & $Customize $root | Out-Null }
    }
}

# Partitions a new disk for UEFI and applies an edition of Windows to it, at low priority (Priority.ps1). The disk
# never gets a drive letter (Explorer, the indexer and AutoPlay don't open it): its volumes are mounted on folders
# under the admin-only mount root while the image is applied.
function New-WindowsBaseVhdx {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ImageFile,
        [Parameter(Mandatory)][int]$ImageIndex
    )
    Write-Step "Preparando Windows de este ISO (solo la primera vez, 5 a 15 minutos; el equipo sigue libre)"
    New-VHD -Path $Path -SizeBytes ([uint64]$script:BaseDiskGB * 1GB) -Dynamic | Out-Null
    Mount-VHD -Path $Path -NoDriveLetter
    $mountRoot = Get-GpuVMMountRoot
    $folders = [ordered]@{ efi = Join-Path $mountRoot ([guid]::NewGuid().ToString('n')); os = Join-Path $mountRoot ([guid]::NewGuid().ToString('n')) }
    $mounted = [System.Collections.Generic.List[object]]::new()
    $efi = $null
    try {
        $diskNumber = (Get-VHD -Path $Path).DiskNumber
        Initialize-Disk -Number $diskNumber -PartitionStyle GPT | Out-Null

        # EFI is created as a basic partition so it can be formatted and mounted; its type is changed at the end.
        $efi = New-Partition -DiskNumber $diskNumber -Size 260MB -GptType $script:GptTypes.Basic
        $efi | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
        if (-not (Get-Partition -DiskNumber $diskNumber | Where-Object GptType -eq $script:GptTypes.Msr)) {
            New-Partition -DiskNumber $diskNumber -Size 16MB -GptType $script:GptTypes.Msr | Out-Null
        }
        $os = New-Partition -DiskNumber $diskNumber -UseMaximumSize -GptType $script:GptTypes.Basic
        $os | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null

        foreach ($pair in @(@($efi, $folders.efi), @($os, $folders.os))) {
            New-Item -ItemType Directory -Path $pair[1] | Out-Null
            Add-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $pair[0].PartitionNumber -AccessPath "$($pair[1])\"
            $mounted.Add($pair)
        }

        $dism = Join-Path $env:SystemRoot 'System32\Dism.exe'
        $code = Invoke-LowPriority -FilePath $dism -ArgumentList '/Apply-Image', "/ImageFile:$ImageFile", "/Index:$ImageIndex", "/ApplyDir:$($folders.os)"
        if ($code -ne 0) { throw "DISM falló al aplicar la imagen (código $code; detalle en $env:SystemRoot\Logs\DISM\dism.log)." }

        & (Join-Path $env:SystemRoot 'System32\bcdboot.exe') "$($folders.os)\Windows" /s "$($folders.efi)" /f UEFI | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "bcdboot falló (código $LASTEXITCODE)." }
    }
    finally {
        foreach ($pair in $mounted) {
            Remove-PartitionAccessPath -DiskNumber $pair[0].DiskNumber -PartitionNumber $pair[0].PartitionNumber -AccessPath "$($pair[1])\" -ErrorAction SilentlyContinue
        }
        if ($efi) { Set-Partition -DiskNumber $efi.DiskNumber -PartitionNumber $efi.PartitionNumber -GptType $script:GptTypes.Efi -ErrorAction SilentlyContinue }
        Dismount-VHD -Path $Path
        # Only empty, plain folders are removed.
        foreach ($folder in $folders.Values) {
            $item = Get-Item -LiteralPath $folder -Force -ErrorAction SilentlyContinue
            if ($item -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { [IO.Directory]::Delete($folder, $false) }
        }
    }
}

# Admin-only folder where existing guest disks are mounted (%ProgramData%\GpuVM\mount).
function Get-GpuVMMountRoot {
    $base = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'GpuVM'
    Initialize-GpuVMRoot -Path $base
    $mount = Join-Path $base 'mount'
    if (-not (Test-Path -LiteralPath $mount)) { New-Item -ItemType Directory -Path $mount | Out-Null }
    if ((Get-Item -LiteralPath $mount -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "$mount es un enlace a otra carpeta; GpuVM no montará discos ahí."
    }
    $mount
}

# Mounts the VHDX of a stopped VM, finds the Windows partition and runs $ScriptBlock with its root.
# The guest's content is untrusted (a damaged or infected VM wrote it): the disk gets no drive letter
# (Explorer, the indexer and antivirus do not open it) and is mounted on an empty folder only administrators can reach.
function Invoke-WithMountedWindows {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        # Grows the Windows partition into the free space at the end of the disk (after Resize-VHD).
        [switch]$ExpandPartition
    )
    $accessPath = Join-Path (Get-GpuVMMountRoot) ([guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $accessPath | Out-Null
    Mount-VHD -Path $Path -NoDriveLetter
    $os = $null
    $dismounted = $false
    try {
        $diskNumber = (Get-VHD -Path $Path).DiskNumber
        $os = Get-Partition -DiskNumber $diskNumber |
            Where-Object GptType -eq $script:GptTypes.Basic |
            Sort-Object Size -Descending |
            Select-Object -First 1
        if (-not $os) { throw "No se encontró la partición de Windows en $Path." }
        # A letter left by an earlier mount is removed so the volume is only reachable through the folder.
        if ($os.DriveLetter) {
            Remove-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $os.PartitionNumber -AccessPath "$($os.DriveLetter):\"
        }
        if ($ExpandPartition) {
            $max = (Get-PartitionSupportedSize -DiskNumber $diskNumber -PartitionNumber $os.PartitionNumber).SizeMax
            if ($max - $os.Size -ge 1MB) { Resize-Partition -DiskNumber $diskNumber -PartitionNumber $os.PartitionNumber -Size $max }
        }
        Add-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $os.PartitionNumber -AccessPath "$accessPath\"
        $root = "$accessPath\"
        if (-not (Test-Path -LiteralPath (Join-Path $root 'Windows\System32'))) { throw "La partición de $Path no contiene Windows." }
        & $ScriptBlock $root
    }
    finally {
        if ($os) {
            Remove-PartitionAccessPath -DiskNumber $os.DiskNumber -PartitionNumber $os.PartitionNumber -AccessPath "$accessPath\" -ErrorAction SilentlyContinue
        }
        try { Dismount-VHD -Path $Path; $dismounted = $true }
        finally {
            # Only an empty, plain folder is removed: if the disk is still mounted there it stays as is.
            $item = Get-Item -LiteralPath $accessPath -Force -ErrorAction SilentlyContinue
            if ($dismounted -and $item -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                [IO.Directory]::Delete($accessPath, $false)
            }
        }
    }
}
