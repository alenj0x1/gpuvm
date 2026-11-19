# Builds the guest agent (release, static CRT) and puts what the host copies into a guest in guest/agent/dist:
# gpuvm-agent.exe and VERSION. The host copies dist/* to C:\ProgramData\GpuVM\Agent\staging (Copy-VMFile) and runs
# install.ps1 over PowerShell Direct.
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    cargo build --release
    if ($LASTEXITCODE) { throw 'cargo build failed' }
    $dist = Join-Path $PSScriptRoot 'dist'
    New-Item -ItemType Directory -Force $dist | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'target\release\gpuvm-agent.exe') $dist -Force
    $version = (& (Join-Path $dist 'gpuvm-agent.exe') version | Out-String).Trim()
    Set-Content (Join-Path $dist 'VERSION') $version -NoNewline -Encoding ascii
    Get-ChildItem $dist | Select-Object Name, Length
}
finally { Pop-Location }
