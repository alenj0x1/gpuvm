function Export-GpuVM {
    <#
    .SYNOPSIS
    Saves a stopped VM to one .gpuvm file: its Windows (with its restore points and template merged in), apps and
    settings, without the Windows password or anything else protected on this PC. Import it with Import-GpuVM.
    .EXAMPLE
    Export-GpuVM -Name win10 -Path D:\Copias\win10.gpuvm
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        # Shuts the VM down cleanly first and starts it again when the copy of its disk is done.
        [switch]$ShutdownIfRunning,
        # Compression of the disk in the file: NoCompression (fastest, default) or Fastest (smaller, slower).
        [ValidateSet('NoCompression', 'Fastest')][string]$Compression = 'NoCompression'
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    $target = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetExtension($target) -ne $script:TransferExtension) { $target += $script:TransferExtension }
    if (Test-Path -LiteralPath $target) { throw "Ya existe $target. Elige otro nombre." }
    $dir = Split-Path $target -Parent
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "No existe la carpeta $dir." }
    $target = Assert-GpuVMExportPath -Path $target
    $source = (Get-VMHardDiskDrive -VMName $Name | Select-Object -First 1).Path
    if (-not $source) { throw "La máquina '$Name' no tiene disco." }
    # The merged copy and the file are both written next to the target: at most twice what the chain takes.
    $chain = Get-VhdChainBytes -Path $source
    $needGB = [math]::Ceiling(2 * $chain / 1GB) + 5
    $freeGB = Get-DriveFreeGB $target
    if ($needGB -gt $freeGB) { throw "No hay espacio en $(Split-Path $target -Qualifier) para exportar: hacen falta hasta $needGB GB y quedan $freeGB GB libres." }
    if (-not $PSCmdlet.ShouldProcess($Name, "Exportar a $target")) { return }

    $restart = Stop-GpuVMForDisk -Name $Name -ShutdownIfRunning:$ShutdownIfRunning -Action 'exportarla'
    $temp = "$target.disk.partial.vhdx"
    $partial = "$target.partial"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        try {
            Write-Step 'Copiando el disco de la máquina'
            Convert-VHD -Path $source -DestinationPath $temp -VHDType Dynamic -ErrorAction Stop
        }
        finally {
            if ($restart) {
                Write-Step 'Encendiendo'
                try { Start-VM -Name $Name -ErrorAction Stop } catch { Write-Warning "No se pudo volver a encender ${Name}: $($_.Exception.Message)" }
            }
        }
        $freed = Compress-GpuVMDiskCopy -Path $temp
        $vhd = Get-VHD -Path $temp
        $manifest = New-TransferManifest -State $state -SizeBytes $vhd.Size
        $length = (Get-Item -LiteralPath $temp).Length

        $file = [IO.File]::Open($partial, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $zip = [IO.Compression.ZipArchive]::new($file, [IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                $entry = $zip.CreateEntry('disk.vhdx', [IO.Compression.CompressionLevel]::$Compression)
                $in = [IO.File]::OpenRead($temp)
                $out = $entry.Open()
                try { $copy = Copy-StreamWithHash -Source $in -Destination $out -Length $length -Label 'Exportando' }
                finally { $out.Dispose(); $in.Dispose() }
                $manifest['disk'] = [ordered]@{ bytes = $copy.Bytes; sha256 = $copy.Sha256 }
                $manifestEntry = $zip.CreateEntry('manifest.json', [IO.Compression.CompressionLevel]::Optimal)
                $writer = [IO.StreamWriter]::new($manifestEntry.Open(), [Text.UTF8Encoding]::new($false))
                try { $writer.Write(($manifest | ConvertTo-Json -Depth 5)) } finally { $writer.Dispose() }
            }
            finally { $zip.Dispose() }
        }
        finally { $file.Dispose() }
        [IO.File]::Move($partial, $target)
    }
    catch {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            if ((Get-VHD -Path $temp -ErrorAction SilentlyContinue).Attached) { Dismount-VHD -Path $temp -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
    $size = (Get-Item -LiteralPath $target).Length
    Write-Step "Máquina exportada ($([math]::Round($size / 1GB, 1)) GB)"
    [ordered]@{
        name       = $Name
        path       = $target
        sizeGB     = [math]::Round($size / 1GB, 2)
        diskGB     = [math]::Round($manifest['disk']['bytes'] / 1GB, 2)
        freedGB    = [math]::Round($freed / 1GB, 2)
        sha256     = $manifest['disk']['sha256']
        seconds    = [math]::Round($sw.Elapsed.TotalSeconds)
    }
}
