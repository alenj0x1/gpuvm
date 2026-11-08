# Unelevated tests against the installed services (install.ps1 first). Output in out\run.txt.
$ErrorActionPreference = 'Continue'
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null
$exe = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'GpuVM-lab\gpuvm-host-lab.exe'
$unlisted = Join-Path $PSScriptRoot 'target\release\gpuvm-host-lab.exe'

& {
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    "elevated=$elevated (debe ser False)"

    foreach ($mode in 'user', 'system') {
        "== $($mode): identidad"
        & $exe client identity --mode $mode 2>&1
        "== $($mode): 30 x Get-GpuVMOverview"
        & $exe client bench 30 --mode $mode 2>&1
    }

    '== crear el pipe del servicio desde un proceso sin elevar (debe fallar)'
    & $exe client squat --mode user 2>&1

    '== cliente fuera de la lista (el mismo programa, en la carpeta del usuario; debe rechazarse)'
    & $unlisted client bench 3 --mode user 2>&1

    '== cliente .NET que pide lectura/escritura genérica (debe negarlo el ACL del pipe)'
    try {
        $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'gpuvm-lab-018-user', [IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(3000)
        $reader = [IO.StreamReader]::new($pipe)
        "conectado; respuesta: $($reader.ReadLine())"
        $pipe.Dispose()
    }
    catch { "rechazado: $($_.Exception.InnerException.Message ?? $_.Exception.Message)" }
} *>&1 | Tee-Object (Join-Path $out 'run.txt')
