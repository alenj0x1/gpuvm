# Builds the guest agent (release, static CRT) and puts what the host copies into a guest in guest/agent/dist:
# gpuvm-agent.exe and VERSION. The host copies dist/* to C:\ProgramData\GpuVM\Agent\staging (Copy-VMFile) and runs
# install.ps1 over PowerShell Direct.
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    # The build output stays outside guest\ (the installer ships guest\ as is): only dist\ goes into it.
    $target = Join-Path $PSScriptRoot '..\..\app\guest-agent-target'
    cargo build --release --target-dir $target
    if ($LASTEXITCODE) { throw 'cargo build failed' }
    $dist = Join-Path $PSScriptRoot 'dist'
    New-Item -ItemType Directory -Force $dist | Out-Null
    Copy-Item (Join-Path $target 'release\gpuvm-agent.exe') $dist -Force
    $version = (& (Join-Path $dist 'gpuvm-agent.exe') version | Out-String).Trim()
    Set-Content (Join-Path $dist 'VERSION') $version -NoNewline -Encoding ascii
    Get-ChildItem $dist | Select-Object Name, Length
}
finally { Pop-Location }
