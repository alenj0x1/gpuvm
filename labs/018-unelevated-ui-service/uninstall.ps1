# Reverts install.ps1: stops and deletes the lab services, keeps the service log in out\ and removes the folders.
# Run elevated.
$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null
Start-Transcript (Join-Path $out 'uninstall.txt') -Force | Out-Null
try {
    foreach ($mode in 'user', 'system') {
        $name = "GpuVMLab018-$mode"
        if (Get-Service $name -ErrorAction SilentlyContinue) {
            Stop-Service $name -Force -ErrorAction SilentlyContinue
            & "$env:SystemRoot\System32\sc.exe" delete $name | Out-Null
            "Servicio $name borrado."
        }
    }
    $data = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'GpuVM-lab'
    $log = Join-Path $data 'host.log'
    foreach ($file in 'host.log', 'bridge-user.err', 'bridge-system.err') {
        $path = Join-Path $data $file
        if (Test-Path $path) { Copy-Item $path (Join-Path $out $file) -Force }
    }
    foreach ($dir in $data, (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'GpuVM-lab')) {
        # The binary may take a moment to be released after the service stops.
        for ($i = 0; $i -lt 10 -and (Test-Path $dir); $i++) {
            try { Remove-Item $dir -Recurse -Force } catch { Start-Sleep -Milliseconds 500 }
        }
        if (Test-Path $dir) { Write-Warning "No se pudo borrar $dir" } else { "Borrado $dir" }
    }
}
finally {
    Stop-Transcript | Out-Null
}
