function Install-GpuVMClient {
    <#
    .SYNOPSIS
    Installs Moonlight on the host with winget. winget may ask you to accept its terms the first time.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (Get-MoonlightPath) {
        Write-Step "Moonlight is already installed: $(Get-MoonlightPath)"
        return
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget wasn''t found. Download Moonlight from https://moonlight-stream.org'
    }
    if (-not $PSCmdlet.ShouldProcess('Moonlight (MoonlightGameStreamingProject.Moonlight)', 'Install with winget')) { return }
    & winget install --id MoonlightGameStreamingProject.Moonlight --exact --silent
    if ($LASTEXITCODE -ne 0) { throw "winget ended with code $LASTEXITCODE." }
    Write-Step "Moonlight installed: $(Get-MoonlightPath)"
}
