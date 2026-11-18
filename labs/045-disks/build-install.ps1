# Builds the app from this worktree (Tauri release + NSIS installer) and installs it silently with lab 039's helper,
# so front 4 can be tried in the real installed app. Run inside a lock turn (run-all.ps1 -Labs build-install.ps1):
# the Rust build takes the CPU and writes GBs. Elevated PowerShell 7.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$app = Join-Path $repo 'app'
$log = Join-Path $PSScriptRoot "out\build-$(Get-Date -Format yyyyMMdd-HHmmss).log"
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew()
Push-Location $app
try {
    & cmd.exe /c "npx tauri build > `"$log`" 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "tauri build failed ($LASTEXITCODE); see $log" }
}
finally { Pop-Location }
$setup = Get-ChildItem (Join-Path $app 'src-tauri\target\release\bundle\nsis') -Filter 'GpuVM_*_x64-setup.exe' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $setup) { throw 'no installer was produced' }
Write-Host "built $($setup.Name) in $([math]::Round($sw.Elapsed.TotalSeconds)) s ($([math]::Round($setup.Length / 1MB, 1)) MB)"
& (Join-Path $repo 'labs\039-viewer-bridge\install-build.ps1') -Setup $setup.FullName
