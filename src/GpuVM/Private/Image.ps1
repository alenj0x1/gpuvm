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

# Creates the VHDX, partitions it for UEFI, applies the chosen edition and sets up boot.
# $Customize receives the root of the applied Windows (e.g. 'X:\') to copy files before dismounting.
function New-WindowsVhdx {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$SizeGB,
        [ValidateSet('Dynamic', 'Fixed')][string]$Type = 'Dynamic',
        [Parameter(Mandatory)][string]$ImageFile,
        [Parameter(Mandatory)][int]$ImageIndex,
        [scriptblock]$Customize
    )
    if (Test-Path -LiteralPath $Path) { throw "Ya existe el disco $Path." }
    $vhdParams = @{ Path = $Path; SizeBytes = [uint64]$SizeGB * 1GB }
    if ($Type -eq 'Fixed') { $vhdParams['Fixed'] = $true } else { $vhdParams['Dynamic'] = $true }

    Write-Step "Creando disco $Type de $SizeGB GB (un disco fijo tarda unos minutos)"
    New-VHD @vhdParams | Out-Null
    Mount-VHD -Path $Path
    $efi = $null
    try {
        $diskNumber = (Get-VHD -Path $Path).DiskNumber
        Initialize-Disk -Number $diskNumber -PartitionStyle GPT | Out-Null

        # EFI is created as a basic partition so it can be formatted and given a letter; its type is changed at the end.
        $efi = New-Partition -DiskNumber $diskNumber -Size 260MB -GptType $script:GptTypes.Basic
        $efi | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
        if (-not (Get-Partition -DiskNumber $diskNumber | Where-Object GptType -eq $script:GptTypes.Msr)) {
            New-Partition -DiskNumber $diskNumber -Size 16MB -GptType $script:GptTypes.Msr | Out-Null
        }
        $os = New-Partition -DiskNumber $diskNumber -UseMaximumSize -GptType $script:GptTypes.Basic
        $os | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null

        $efi | Add-PartitionAccessPath -AssignDriveLetter | Out-Null
        $os | Add-PartitionAccessPath -AssignDriveLetter | Out-Null
        $efi = Get-Partition -DiskNumber $diskNumber -PartitionNumber $efi.PartitionNumber
        $os = Get-Partition -DiskNumber $diskNumber -PartitionNumber $os.PartitionNumber
        $osRoot = "$($os.DriveLetter):\"

        Write-Step 'Aplicando la imagen de Windows (5 a 15 minutos)'
        # Out-Host: DISM output must not mix with what the function returns.
        & dism.exe /Apply-Image "/ImageFile:$ImageFile" "/Index:$ImageIndex" "/ApplyDir:$osRoot" | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "DISM falló al aplicar la imagen (código $LASTEXITCODE)." }

        & bcdboot.exe "$($osRoot)Windows" /s "$($efi.DriveLetter):" /f UEFI | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "bcdboot falló (código $LASTEXITCODE)." }

        if ($Customize) { & $Customize $osRoot | Out-Null }
    }
    finally {
        if ($efi -and $efi.DriveLetter) {
            Remove-PartitionAccessPath -DiskNumber $efi.DiskNumber -PartitionNumber $efi.PartitionNumber -AccessPath "$($efi.DriveLetter):\" -ErrorAction SilentlyContinue
            Set-Partition -DiskNumber $efi.DiskNumber -PartitionNumber $efi.PartitionNumber -GptType $script:GptTypes.Efi -ErrorAction SilentlyContinue
        }
        Dismount-VHD -Path $Path
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
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
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
