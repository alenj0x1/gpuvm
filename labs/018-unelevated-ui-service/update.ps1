# Replaces the installed lab binary with the new build and restarts both services. Run elevated.
# The log folder becomes readable (not writable) by the user, so run.ps1 can show the service's diagnostics.
$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot 'out'
Start-Transcript (Join-Path $out 'update.txt') -Force | Out-Null
try {
    $modes = 'user', 'system'
    foreach ($mode in $modes) {
        Stop-Service "GpuVMLab018-$mode" -Force -ErrorAction SilentlyContinue
        (Get-Service "GpuVMLab018-$mode").WaitForStatus('Stopped', [TimeSpan]::FromSeconds(10))
    }
    $exe = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'GpuVM-lab\gpuvm-host-lab.exe'
    for ($i = 0; $i -lt 10; $i++) {
        try { Copy-Item (Join-Path $PSScriptRoot 'target\release\gpuvm-host-lab.exe') $exe -Force; break } catch { Start-Sleep -Milliseconds 500 }
    }
    $data = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'GpuVM-lab'
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & "$env:SystemRoot\System32\icacls.exe" $data /grant "*${sid}:(OI)(CI)R" | Out-Null
    foreach ($mode in $modes) { Start-Service "GpuVMLab018-$mode" }
    Get-Service GpuVMLab018-* | Format-Table -AutoSize Name, Status | Out-String
}
finally {
    Stop-Transcript | Out-Null
}
