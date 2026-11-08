# Interleaved rounds (direct, service user, service system) so all three see the same machine state. Run elevated:
# direct needs it; the service clients don't care (same program, same user). Output in out\bench-all.txt.
param([int]$Rounds = 3, [int]$N = 30)
$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot 'out'
$programFiles = [Environment]::GetFolderPath('ProgramFiles')
$exe = Join-Path $programFiles 'GpuVM-lab\gpuvm-host-lab.exe'
$pwsh = Join-Path $programFiles 'GpuVM-lab\pwsh\pwsh.exe'
$codeRoot = Join-Path $programFiles 'GpuVM\gpuvm'
& {
    "VMs encendidas: $(@(Get-VM | Where-Object State -eq 'Running').Count)"
    for ($r = 1; $r -le $Rounds; $r++) {
        "== ronda $r"
        & $exe bench-direct $N --code-root $codeRoot --pwsh $pwsh 2>&1
        & $exe client bench $N --mode user 2>&1
        & $exe client bench $N --mode system 2>&1
    }
} *>&1 | Tee-Object (Join-Path $out 'bench-all.txt')
