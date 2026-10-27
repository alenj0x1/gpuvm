# External components (Sunshine, virtual display, nefcon) with version and SHA-256 pinned in streaming/components.json.
# They are downloaded once on the host, verified and copied to the VM disk; the guest downloads nothing.

# If components were updated in an installation, the editable copy lives in the data folder; otherwise, the code one.
function Get-ComponentManifestPath {
    param([switch]$ForWrite)
    $data = Join-Path $script:DataRoot 'streaming\components.json'
    if ($ForWrite -or (Test-Path -LiteralPath $data)) { return $data }
    Get-RepoPath 'streaming\components.json'
}

function Get-ComponentManifest { Read-JsonFile (Get-ComponentManifestPath) }

function Get-ComponentCacheRoot {
    if ($env:GPUVM_CACHE_ROOT) { return $env:GPUVM_CACHE_ROOT }
    Get-DataPath 'cache'
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

# Returns the local path of the component; downloads it if not cached. Never uses a file whose hash does not match.
function Save-GpuVMComponent {
    param(
        [Parameter(Mandatory)][string]$Name,
        [System.Collections.IDictionary]$Manifest = (Get-ComponentManifest)
    )
    if (-not $Manifest.Contains($Name)) { throw "Componente desconocido '$Name'." }
    $c = $Manifest[$Name]
    $dir = Join-Path (Get-ComponentCacheRoot) "$Name\$($c['version'])"
    $path = Join-Path $dir $c['file']
    if ((Test-Path -LiteralPath $path) -and (Get-FileSha256 $path) -eq $c['sha256']) { return $path }

    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Write-Step "Descargando $Name $($c['version'])"
    $partial = "$path.part"
    Invoke-WebRequest -Uri $c['url'] -OutFile $partial -UseBasicParsing
    $hash = Get-FileSha256 $partial
    if ($hash -ne $c['sha256']) {
        Remove-Item -LiteralPath $partial -Force
        throw "El SHA-256 de $Name no coincide (esperado $($c['sha256']), recibido $hash). No se usará el archivo."
    }
    Move-Item -LiteralPath $partial -Destination $path -Force
    $path
}
