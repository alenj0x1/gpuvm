<#
.SYNOPSIS
Builds GpuVM for testing (fast Rust profile, uncompressed installer) and installs it silently.
.DESCRIPTION
Releases keep the release profile (tauri build). This one skips LTO and the installer's LZMA compression.
The installer still asks for UAC: the service trusts only Program Files\GpuVM\gpuvm.exe.
.EXAMPLE
pwsh -File scripts/dev-install.ps1
#>
param([switch]$NoInstall)
$ErrorActionPreference = 'Stop'
$app = Join-Path $PSScriptRoot '..\app'
$sw = [Diagnostics.Stopwatch]::StartNew()
Push-Location $app
try {
    npx tauri build --config src-tauri/tauri.fast.conf.json -- --profile fast
    if ($LASTEXITCODE) { throw "tauri build failed ($LASTEXITCODE)" }
}
finally { Pop-Location }
$setup = Get-ChildItem (Join-Path $app 'src-tauri\target\fast\bundle\nsis') -Filter '*-setup.exe' | Sort-Object LastWriteTime | Select-Object -Last 1
Write-Host "Built in $([int]$sw.Elapsed.TotalSeconds) s: $($setup.FullName)"
if (-not $NoInstall) { & (Join-Path $PSScriptRoot '..\labs\039-viewer-bridge\install-build.ps1') -Setup $setup.FullName }
