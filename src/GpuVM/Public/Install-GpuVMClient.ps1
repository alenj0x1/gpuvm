function Install-GpuVMClient {
    <#
    .SYNOPSIS
    Installs Moonlight on the host with winget. winget may ask you to accept its terms the first time.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (Get-MoonlightPath) {
        Write-Step "Moonlight ya está instalado: $(Get-MoonlightPath)"
        return
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'No se encontró winget. Descarga Moonlight desde https://moonlight-stream.org'
    }
    if (-not $PSCmdlet.ShouldProcess('Moonlight (MoonlightGameStreamingProject.Moonlight)', 'Instalar con winget')) { return }
    & winget install --id MoonlightGameStreamingProject.Moonlight --exact --silent
    if ($LASTEXITCODE -ne 0) { throw "winget terminó con código $LASTEXITCODE." }
    Write-Step "Moonlight instalado: $(Get-MoonlightPath)"
}
