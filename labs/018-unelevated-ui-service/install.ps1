# Installs the lab's two services (bridge as the elevated user, bridge as SYSTEM) and measures the baseline.
# Run elevated. Revert with uninstall.ps1. Output in out\.
$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null
Start-Transcript (Join-Path $out 'install.txt') -Force | Out-Null
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Corre este script como administrador.'
    }
    $modes = 'user', 'system'
    foreach ($mode in $modes) {
        if (Get-Service "GpuVMLab018-$mode" -ErrorAction SilentlyContinue) { throw "GpuVMLab018-$mode ya existe: corre uninstall.ps1 primero." }
    }

    # The service binary only in a folder that only administrators can change, never in the user's repo.
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $dest = Join-Path $programFiles 'GpuVM-lab'
    $exe = Join-Path $dest 'gpuvm-host-lab.exe'
    New-Item -ItemType Directory -Force $dest | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'target\release\gpuvm-host-lab.exe') $exe -Force

    # Log folder: SYSTEM and Administrators only.
    $data = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'GpuVM-lab'
    New-Item -ItemType Directory -Force $data | Out-Null
    & "$env:SystemRoot\System32\icacls.exe" $data /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null

    # The installed GpuVM (Program Files) and PowerShell 7 from the Store, as the app uses them.
    $codeRoot = Join-Path $programFiles 'GpuVM\gpuvm'
    if (-not (Test-Path (Join-Path $codeRoot 'src\bridge.ps1'))) { throw "No está GpuVM instalado en $codeRoot." }
    $package = Get-AppxPackage -Name Microsoft.PowerShell | Sort-Object Version -Descending | Select-Object -First 1
    $pwsh = if ($package) { Join-Path $package.InstallLocation 'pwsh.exe' } else { Join-Path $programFiles 'PowerShell\7\pwsh.exe' }
    if (-not (Test-Path $pwsh)) { throw 'No se encontró PowerShell 7.' }
    $sid = $identity.User.Value
    "exe=$exe`ncodeRoot=$codeRoot`npwsh=$pwsh`nsid=$sid"

    foreach ($mode in $modes) {
        $bin = "`"$exe`" service --mode $mode --allow `"$exe`" --user-sid $sid --code-root `"$codeRoot`" --pwsh `"$pwsh`""
        New-Service -Name "GpuVMLab018-$mode" -DisplayName "GpuVM lab 018 ($mode)" -BinaryPathName $bin -StartupType Manual | Out-Null
        Start-Service "GpuVMLab018-$mode"
        Get-Service "GpuVMLab018-$mode" | Format-Table -AutoSize Name, Status | Out-String
    }

    # Baseline: the bridge spawned directly by an elevated process, as gpuvm.exe does today.
    & $exe bench-direct 30 --code-root $codeRoot --pwsh $pwsh 2>&1 | Tee-Object (Join-Path $out 'direct.json')
}
finally {
    Stop-Transcript | Out-Null
}
