function Import-GpuVMSharedDisk {
    <#
    .SYNOPSIS
    Copies a folder of this PC into a shared disk (for example, a Steam library, so games don't download again in the
    VM). The disk must not be attached to a running VM. A Steam library (a folder with steamapps) goes into
    SteamLibrary; anything else into a folder with its own name. Only copies host -> disk: nothing comes back.
    .EXAMPLE
    Import-GpuVMSharedDisk -Name juegos -Path 'D:\SteamLibrary'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name,
        [Parameter(Mandatory)][string]$Path
    )
    Assert-Admin
    $disk = Read-SharedDisk -Name $Name
    $source = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "No existe la carpeta $source." }
    Assert-ImportableFolder -Path $source
    $attachment = Get-SharedDiskAttachment -Path $disk['path']
    if ($attachment) {
        if ((Get-VM -Name $attachment.VMName).State -ne 'Off') { throw "Desconecta el disco '$Name' de '$($attachment.VMName)' o apágala antes de importar." }
    }

    # A Steam library (or Steam's own folder) brings only its games: steamapps goes to SteamLibrary\steamapps.
    $folder = Split-Path $source -Leaf
    if (-not $folder -or $folder -match '[:\\]') { $folder = 'Importado' }
    if (Test-Path -LiteralPath (Join-Path $source 'steamapps') -PathType Container) {
        $source = Join-Path $source 'steamapps'
        $folder = 'SteamLibrary\steamapps'
    }
    Write-Step 'Midiendo la carpeta'
    # Links in the source are skipped (robocopy /XJ), so they are not counted either.
    $total = [int64](Get-ChildItem -LiteralPath $source -Recurse -File -Force -Attributes !ReparsePoint -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum

    $accessPath = Join-Path (Get-GpuVMMountRoot) ([guid]::NewGuid().ToString('n'))
    $partition = $null
    $mounted = $false
    try {
        # Hyper-V keeps the disk open while attached, even with the VM off; it is attached again in finally.
        if ($attachment) { $attachment | Remove-VMHardDiskDrive }
        New-Item -ItemType Directory -Path $accessPath | Out-Null
        Mount-VHD -Path $disk['path'] -NoDriveLetter
        $mounted = $true
        $number = (Get-VHD -Path $disk['path']).DiskNumber
        $partition = Get-Partition -DiskNumber $number | Where-Object Type -eq 'Basic' | Sort-Object Size -Descending | Select-Object -First 1
        if (-not $partition) { throw "El disco '$Name' no tiene una partición de datos." }
        if ($partition.DriveLetter) { Remove-PartitionAccessPath -DiskNumber $number -PartitionNumber $partition.PartitionNumber -AccessPath "$($partition.DriveLetter):\" }
        Add-PartitionAccessPath -DiskNumber $number -PartitionNumber $partition.PartitionNumber -AccessPath "$accessPath\"
        $volume = Get-Volume -Partition $partition
        if ($total + 1GB -gt $volume.SizeRemaining) {
            throw "No cabe: la carpeta ocupa $([math]::Ceiling($total / 1GB)) GB y el disco tiene $([math]::Floor($volume.SizeRemaining / 1GB)) GB libres."
        }
        $target = Join-Path $accessPath $folder
        # A VM wrote to this disk: a link planted anywhere under the target would send this copy out of the disk.
        Assert-NoReparsePoint -Root $accessPath -Path $target
        if (Test-Path -LiteralPath $target) { Assert-NoReparsePointBelow -Root $accessPath -Path $target }

        Write-Step "Copiando a $folder"
        $startFree = $volume.SizeRemaining
        $log = Join-Path ([IO.Path]::GetTempPath()) "gpuvm-import-$([guid]::NewGuid().ToString('n')).log"
        $robocopy = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\robocopy.exe') -PassThru -WindowStyle Hidden -ArgumentList @(
            "`"$source`"", "`"$target`"", '/E', '/XJ', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/MT:8', '/NP', '/NFL', '/NDL', "/LOG:`"$log`"")
        # Progress from the space the disk has used so far: cheap, and right even with many small files.
        while (-not $robocopy.WaitForExit(2000)) {
            $copied = $startFree - (Get-Volume -Partition $partition).SizeRemaining
            if ($total -gt 0) { Write-Step "Copiando $([math]::Min(99, [math]::Floor(100 * $copied / $total))) %" }
        }
        # Robocopy: 0-7 copied (with or without differences); 8 or more, some files failed.
        if ($robocopy.ExitCode -ge 8) {
            $tail = (Get-Content -LiteralPath $log -Tail 5 -ErrorAction SilentlyContinue) -join ' '
            throw "Algunos archivos no se copiaron (robocopy $($robocopy.ExitCode)). $tail"
        }
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        Write-Step "Copiado: $([math]::Round($total / 1GB, 1)) GB en $folder"
    }
    finally {
        if ($partition) { Remove-PartitionAccessPath -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -AccessPath "$accessPath\" -ErrorAction SilentlyContinue }
        $dismounted = -not $mounted
        try { if ($mounted) { Dismount-VHD -Path $disk['path']; $dismounted = $true } }
        finally {
            $item = Get-Item -LiteralPath $accessPath -Force -ErrorAction SilentlyContinue
            if ($dismounted -and $item -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { [IO.Directory]::Delete($accessPath, $false) }
        }
        if ($attachment) { Add-VMHardDiskDrive -VMName $attachment.VMName -ControllerType SCSI -Path $disk['path'] }
    }
    [ordered]@{ name = $Name; folder = $folder; copiedGB = [math]::Round($total / 1GB, 1) }
}
