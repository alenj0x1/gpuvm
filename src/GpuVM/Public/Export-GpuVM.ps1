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
    Assert-GpuVMNotDisposable -State $state -Action 'exportar'
    $target = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetExtension($target) -ne $script:TransferExtension) { $target += $script:TransferExtension }
    $dir = Split-Path $target -Parent
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "No existe la carpeta $dir." }
    $target = Assert-GpuVMExportPath -Path $target
    $source = (Get-VMHardDiskDrive -VMName $Name | Select-Object -First 1).Path
    if (-not $source) { throw "La máquina '$Name' no tiene disco." }
    # The merged copy is made in GpuVM's own folder and the file in the chosen one: each needs up to what the chain takes.
    $chain = Get-VhdChainBytes -Path $source
    $root = Get-GpuVMDefaultRoot
    $chainGB = [math]::Ceiling($chain / 1GB) + 5
    $sameDrive = (Split-Path $root -Qualifier) -eq (Split-Path $target -Qualifier)
    foreach ($check in @(@($root, $(if ($sameDrive) { 2 * $chainGB } else { $chainGB })), @($target, $chainGB))) {
        if ($sameDrive -and $check[0] -eq $target) { continue }
        $freeGB = Get-DriveFreeGB $check[0]
        if ($check[1] -gt $freeGB) { throw "No hay espacio en $(Split-Path $check[0] -Qualifier) para exportar: hacen falta hasta $($check[1]) GB y quedan $freeGB GB libres." }
    }
    if (-not $PSCmdlet.ShouldProcess($Name, "Exportar a $target")) { return }

    # The destination file is created now, once, and checked to be exactly where it was asked (no folder of the path
    # swapped for a link since the service checked it as the user). Everything after writes and, on failure, deletes it
    # through this handle, never through its path again.
    $file = New-GpuVMSafeFile -Path $target
    # The merged disk is made in a folder only administrators can write (inside GpuVM's root), never in the user's folder.
    Initialize-GpuVMRoot -Path $root
    $staging = Join-Path $root ".staging\export-$([guid]::NewGuid().ToString('n'))"
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    $temp = Join-Path $staging 'disk.vhdx'
    $ok = $false
    $restart = $false
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $restart = Stop-GpuVMForDisk -Name $Name -ShutdownIfRunning:$ShutdownIfRunning -Action 'exportarla'
        try {
            Write-Step 'Copying the machine''s disk'
            Convert-VHD -Path $source -DestinationPath $temp -VHDType Dynamic -ErrorAction Stop
        }
        finally {
            if ($restart) {
                Write-Step 'Starting'
                try { Start-VM -Name $Name -ErrorAction Stop } catch { Write-Warning "No se pudo volver a encender ${Name}: $($_.Exception.Message)" }
            }
        }
        $freed = Compress-GpuVMDiskCopy -Path $temp
        $vhd = Get-VHD -Path $temp
        $manifest = New-TransferManifest -State $state -SizeBytes $vhd.Size
        $length = (Get-Item -LiteralPath $temp).Length

        $zip = [IO.Compression.ZipArchive]::new($file, [IO.Compression.ZipArchiveMode]::Create, $true)
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
        $file.Flush($true)
        $size = $file.Length
        $ok = $true
    }
    finally {
        # A file that didn't finish is deleted through its handle.
        Close-GpuVMNewFile -Stream $file -Discard:(-not $ok)
        if (Test-Path -LiteralPath $temp) {
            $vhdInfo = Get-VHD -Path $temp -ErrorAction SilentlyContinue; if ($vhdInfo -and $vhdInfo.Attached) { Dismount-VHD -Path $temp -ErrorAction SilentlyContinue }
        }
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
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