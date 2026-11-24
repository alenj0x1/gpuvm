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
    # Wintun: the adapter isolated HCS machines reach the internet through (vendor\wintun\README.md).
    $wintun = Join-Path $PSScriptRoot 'vendor\wintun\wintun.dll'
    if ((Get-FileHash $wintun -Algorithm SHA256).Hash -ne 'E5DA8447DC2C320EDC0FC52FA01885C103DE8C118481F683643CACC3220DAFCE') { throw 'vendor\wintun\wintun.dll is not Wintun 0.14.1' }
    Copy-Item $wintun $dist -Force
    Copy-Item (Join-Path $PSScriptRoot 'vendor\wintun\LICENSE.txt') (Join-Path $dist 'wintun-LICENSE.txt') -Force
    $version = (& (Join-Path $dist 'gpuvm-agent.exe') version | Out-String).Trim()
    Set-Content (Join-Path $dist 'VERSION') $version -NoNewline -Encoding ascii
    Get-ChildItem $dist | Select-Object Name, Length
}
finally { Pop-Location }
