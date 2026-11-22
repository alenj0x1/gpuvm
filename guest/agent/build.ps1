$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    # Only dist\ goes into guest\: the installer ships guest\ as is.
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
