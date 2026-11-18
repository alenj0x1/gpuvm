# The real PC is shared by several sessions: GPU/latency measurements, VM start/stop, heavy disk work and installs
# take C:\GpuVM\.lab-lock first (created exclusively; fails if it exists). Who is next is in C:\GpuVM\.lab-queue, one
# session name per line: the lock may be taken only when the queue is empty or this session is its first line (and
# that line is removed when it is). Dot-source this file.

$script:LabLockPath = 'C:\GpuVM\.lab-lock'
$script:LabQueuePath = 'C:\GpuVM\.lab-queue'

function Get-LabQueue { @(Get-Content -LiteralPath $script:LabQueuePath -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }) }

function Enter-LabLock {
    param([Parameter(Mandatory)][string]$Owner, [Parameter(Mandatory)][string]$Doing, [int]$WaitMinutes = 60)
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    while ($true) {
        $queue = Get-LabQueue
        $myTurn = -not $queue.Count -or $queue[0].Trim() -eq $Owner
        if (-not $myTurn -and $queue -notcontains $Owner) { Add-Content -LiteralPath $script:LabQueuePath -Value $Owner; $queue = Get-LabQueue }
        if ($myTurn) {
            try {
                $stream = [IO.File]::Open($script:LabLockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $bytes = [Text.Encoding]::UTF8.GetBytes("$Owner | $Doing | $(Get-Date -Format o)")
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Dispose()
                $rest = @(Get-LabQueue | Where-Object { $_.Trim() -ne $Owner })
                Set-Content -LiteralPath $script:LabQueuePath -Value $rest
                return
            }
            catch [IO.IOException] { }
        }
        if ((Get-Date) -gt $deadline) { throw "No llegó el turno del candado: $(Get-Content -Raw $script:LabLockPath -ErrorAction SilentlyContinue)" }
        Write-Host "Esperando el candado (cola: $($queue -join ', ')): $(Get-Content -Raw $script:LabLockPath -ErrorAction SilentlyContinue)"
        Start-Sleep -Seconds 30
    }
}

function Exit-LabLock {
    param([Parameter(Mandatory)][string]$Owner)
    $text = Get-Content -Raw $script:LabLockPath -ErrorAction SilentlyContinue
    if ($text -and $text.StartsWith("$Owner |")) { Remove-Item -LiteralPath $script:LabLockPath -Force }
}
