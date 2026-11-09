# Windows bases: an ISO's edition applied once to a small read-only disk that has never booted (Windows is still
# generalized, as it comes in the ISO). Every new VM from that edition starts as a copy of it instead of applying the
# image again: the slow part (DISM unpacking ~20,000 files) happens once per ISO and edition. Copies don't depend on
# the base, so a base can be deleted any time. Bases live in <root>\.bases\<key>\, readable only by Administrators
# and SYSTEM; the key identifies the image itself (name, version, size, dates), not where the ISO is.

# Bumped when the base's layout changes, so old bases are no longer used.
$script:BaseFormat = 1
# A base is small and grows to the VM's size when copied (profiles ask for at least 64 GB).
$script:BaseDiskGB = 32

function Get-BaseRoot { Join-Path (Get-GpuVMDefaultRoot) '.bases' }

function Get-WindowsImageKey {
    param(
        [Parameter(Mandatory)][string]$ImageFile,
        [Parameter(Mandatory)][int]$ImageIndex
    )
    Import-DismCompat
    $i = Get-WindowsImage -ImagePath $ImageFile -Index $ImageIndex
    $text = "$script:BaseFormat|$($i.ImageName)|$($i.Version)|$($i.ImageSize)|$($i.CreatedTime)|$($i.ModifiedTime)|$($i.Architecture)|$(@($i.Languages) -join ',')"
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))
    [Convert]::ToHexString($hash, 0, 8).ToLowerInvariant()
}

# The base's metadata (base.json) with its paths taken from where it really is.
function Read-WindowsBase {
    param([Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{16}$')][string]$Key)
    $dir = Join-Path (Get-BaseRoot) $Key
    $vhdPath = Join-Path $dir 'base.vhdx'
    if (-not (Test-Path -LiteralPath $vhdPath)) { return $null }
    $metaPath = Join-Path $dir 'base.json'
    $meta = if (Test-Path -LiteralPath $metaPath) { try { Read-JsonFile $metaPath } catch { [ordered]@{} } } else { [ordered]@{} }
    $meta['key'] = $Key
    $meta['dir'] = $dir
    $meta['vhdPath'] = $vhdPath
    $meta
}

# The base disk for an ISO's edition, made now if there is none yet.
function Get-WindowsBaseDisk {
    param(
        [Parameter(Mandatory)][string]$ImageFile,
        [Parameter(Mandatory)][int]$ImageIndex,
        [string]$Edition,
        [string]$Language
    )
    $key = Get-WindowsImageKey -ImageFile $ImageFile -ImageIndex $ImageIndex
    $base = Read-WindowsBase -Key $key
    if ($base) {
        Write-Step 'Windows de este ISO ya está preparado; se copia'
        return $base['vhdPath']
    }

    $root = Get-BaseRoot
    Initialize-GpuVMRoot -Path (Get-GpuVMDefaultRoot)
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Protect-GpuVMSharedFolder -Path $root
    $dir = Join-Path $root $key
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    # The base takes about what Windows uses (~10-15 GB), and the VM's copy as much again.
    $freeGB = Get-DriveFreeGB $root
    if ($freeGB -lt 40) { throw "No hay espacio para preparar Windows: hacen falta unos 40 GB libres y quedan $freeGB GB." }
    # A build cut short (GpuVM closed, PC off) leaves its file behind; one still mounted is another build in progress.
    foreach ($old in Get-ChildItem -LiteralPath $dir -Filter 'building-*.vhdx' -File -ErrorAction SilentlyContinue) {
        if (-not (Get-VHD -Path $old.FullName -ErrorAction SilentlyContinue).Attached) { Remove-Item -LiteralPath $old.FullName -Force }
    }

    $building = Join-Path $dir "building-$([guid]::NewGuid().ToString('n')).vhdx"
    $vhdPath = Join-Path $dir 'base.vhdx'
    try {
        New-WindowsBaseVhdx -Path $building -ImageFile $ImageFile -ImageIndex $ImageIndex
        (Get-Item -LiteralPath $building).IsReadOnly = $true
        Write-JsonFile -Path (Join-Path $dir 'base.json') -Data ([ordered]@{
                edition   = $Edition
                language  = $Language
                imageFile = $ImageFile
                createdAt = (Get-Date).ToString('o')
            })
        # Another creation may have finished the same base meanwhile: its copy is used and this one dropped.
        if (Test-Path -LiteralPath $vhdPath) { throw [System.OperationCanceledException]::new() }
        Move-Item -LiteralPath $building -Destination $vhdPath
    }
    catch [System.OperationCanceledException] { }
    finally {
        if (Test-Path -LiteralPath $building) {
            if ((Get-VHD -Path $building -ErrorAction SilentlyContinue).Attached) { Dismount-VHD -Path $building -ErrorAction SilentlyContinue }
            (Get-Item -LiteralPath $building).IsReadOnly = $false
            Remove-Item -LiteralPath $building -Force -ErrorAction SilentlyContinue
        }
    }
    $vhdPath
}
