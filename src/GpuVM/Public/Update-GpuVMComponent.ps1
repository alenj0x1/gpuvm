function Update-GpuVMComponent {
    <#
    .SYNOPSIS
    Looks up the latest version of each component on GitHub and updates version, URL and SHA-256 in streaming/components.json.
    A new version is untested: validate it in a lab before creating VMs with it.
    .EXAMPLE
    Update-GpuVMComponent -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$Name)
    $manifest = Get-ComponentManifest
    $names = if ($Name) { $Name } else { @($manifest.Keys) }
    $changed = $false
    foreach ($key in $names) {
        $c = $manifest[$key]
        if (-not $c) { Write-Warning "Componente desconocido: $key"; continue }
        if (-not $c['repo']) { Write-Warning "$key no se publica en GitHub; revisa $($c['homepage']) y actualiza versión, URL y SHA-256 a mano."; continue }
        $release = Invoke-RestMethod "https://api.github.com/repos/$($c['repo'])/releases/latest" -Headers @{ 'User-Agent' = 'GpuVM' }
        $asset = $release.assets | Where-Object name -match $c['assetPattern'] | Select-Object -First 1
        if (-not $asset) { Write-Warning "$key $($release.tag_name): ningún archivo coincide con $($c['assetPattern'])"; continue }
        $sha256 = if ($asset.digest -match '^sha256:([0-9a-f]{64})$') { $Matches[1] } else { $null }
        if (-not $sha256) { Write-Warning "$key $($release.tag_name): GitHub no publica SHA-256; se omite."; continue }

        $result = [pscustomobject]@{ Component = $key; Current = $c['version']; Latest = $release.tag_name; Updated = $false }
        if ($release.tag_name -ne $c['version'] -and $PSCmdlet.ShouldProcess($key, "Actualizar de $($c['version']) a $($release.tag_name)")) {
            $c['version'] = $release.tag_name
            $c['file'] = $asset.name
            $c['url'] = $asset.browser_download_url
            $c['sha256'] = $sha256
            $result.Updated = $true
            $changed = $true
        }
        $result
    }
    if ($changed) { Write-JsonFile -Path (Get-ComponentManifestPath -ForWrite) -Data $manifest }
}
