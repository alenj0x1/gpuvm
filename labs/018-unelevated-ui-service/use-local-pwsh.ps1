# The Store's PowerShell only runs for users with the package's identity, which a process started by a service
# does not get. This copies the same signed files to Program Files\GpuVM-lab\pwsh (admin-only, normal ACLs) and
# points the "user" service at that copy. Run elevated; uninstall.ps1 removes it with the rest.
$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot 'out'
Start-Transcript (Join-Path $out 'use-local-pwsh.txt') -Force | Out-Null
try {
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $package = Get-AppxPackage -Name Microsoft.PowerShell | Sort-Object Version -Descending | Select-Object -First 1
    $dest = Join-Path $programFiles 'GpuVM-lab\pwsh'
    & "$env:SystemRoot\System32\robocopy.exe" $package.InstallLocation $dest /E /NFL /NDL /NJH /NJS /NP /XD AppxMetadata | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy falló ($LASTEXITCODE)" }
    $pwsh = Join-Path $dest 'pwsh.exe'
    "firma de la copia: $((Get-AuthenticodeSignature $pwsh).Status)"

    $exe = Join-Path $programFiles 'GpuVM-lab\gpuvm-host-lab.exe'
    $codeRoot = Join-Path $programFiles 'GpuVM\gpuvm'
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $bin = "`"$exe`" service --mode user --allow `"$exe`" --user-sid $sid --code-root `"$codeRoot`" --pwsh `"$pwsh`""
    Stop-Service GpuVMLab018-user -Force -ErrorAction SilentlyContinue
    (Get-Service GpuVMLab018-user).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(10))
    # Straight to the service's ImagePath: Windows PowerShell drops the inner quotes when passing it to sc.exe.
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\GpuVMLab018-user' -Name ImagePath -Value $bin
    Start-Service GpuVMLab018-user

    # Baseline again with the same copy, so both sides use the same pwsh.
    & $exe bench-direct 30 --code-root $codeRoot --pwsh $pwsh 2>&1 | Tee-Object (Join-Path $out 'direct-local-pwsh.json')
}
finally {
    Stop-Transcript | Out-Null
}
