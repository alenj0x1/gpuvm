# The real PC is shared by several sessions: GPU/latency measurements, VM start/stop and installs take
# C:\GpuVM\.lab-lock first (created exclusively; fails if it exists). Dot-source this file.

$script:LabLockPath = 'C:\GpuVM\.lab-lock'

function Enter-LabLock {
    param([Parameter(Mandatory)][string]$Owner, [Parameter(Mandatory)][string]$Doing, [int]$WaitMinutes = 20)
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    while ($true) {
        try {
            $stream = [IO.File]::Open($script:LabLockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $bytes = [Text.Encoding]::UTF8.GetBytes("$Owner | $Doing | $(Get-Date -Format o)")
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Dispose()
            return
        }
        catch [IO.IOException] {
            if ((Get-Date) -gt $deadline) { throw "El candado lo tiene otro: $(Get-Content -Raw $script:LabLockPath -ErrorAction SilentlyContinue)" }
            Write-Host "Esperando el candado: $(Get-Content -Raw $script:LabLockPath -ErrorAction SilentlyContinue)"
            Start-Sleep -Seconds 30
        }
    }
}

function Exit-LabLock {
    param([Parameter(Mandatory)][string]$Owner)
    $text = Get-Content -Raw $script:LabLockPath -ErrorAction SilentlyContinue
    if ($text -and $text.StartsWith("$Owner |")) { Remove-Item -LiteralPath $script:LabLockPath -Force }
}
