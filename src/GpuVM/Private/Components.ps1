function Get-ComponentManifestPath {
    param([switch]$ForWrite)
    $data = Join-Path $script:DataRoot 'streaming\components.json'
    if ($ForWrite -or (Test-Path -LiteralPath $data)) { return $data }
    Get-RepoPath 'streaming\components.json'
}

function Get-ComponentManifest {
    $manifest = Read-JsonFile (Get-ComponentManifestPath)
    $shipped = Get-RepoPath 'streaming\components.json'
    if ((Get-ComponentManifestPath) -ne $shipped -and (Test-Path -LiteralPath $shipped)) {
        $base = Read-JsonFile $shipped
        foreach ($name in $base.Keys) { if (-not $manifest.Contains($name)) { $manifest[$name] = $base[$name] } }
    }
    $manifest
}

function Get-ComponentCacheRoot {
    # The override is for tests; an elevated process ignores it (see GpuVM.psm1).
    if ($env:GPUVM_CACHE_ROOT -and -not $script:IsElevated) { return $env:GPUVM_CACHE_ROOT }
    Get-DataPath 'cache'
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Save-GpuVMComponent {
    param(
        [Parameter(Mandatory)][string]$Name,
        [System.Collections.IDictionary]$Manifest = (Get-ComponentManifest)
    )
    if (-not $Manifest.Contains($Name)) { throw "Unknown component '$Name'." }
    $c = $Manifest[$Name]
    $dir = Join-Path (Get-ComponentCacheRoot) "$Name\$($c['version'])"
    $path = Join-Path $dir $c['file']
    if ((Test-Path -LiteralPath $path) -and (Get-FileSha256 $path) -eq $c['sha256']) { return $path }

    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Write-Step "Downloading $Name $($c['version'])"
    $partial = "$path.part"
    Invoke-WebRequest -Uri $c['url'] -OutFile $partial -UseBasicParsing
    $hash = Get-FileSha256 $partial
    if ($hash -ne $c['sha256']) {
        Remove-Item -LiteralPath $partial -Force
        throw "The SHA-256 of $Name doesn't match (expected $($c['sha256']), got $hash). The file won't be used."
    }
    Move-Item -LiteralPath $partial -Destination $path -Force
    $path
}
