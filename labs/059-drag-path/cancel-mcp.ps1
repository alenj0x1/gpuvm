<#
.SYNOPSIS
    Lab 059, the take-over check done the way it happens: an MCP session (gpuvm.exe --mcp, the installed app) takes the
    machine and draws a 10 s spiral with `drag`; 2 s in, Suspend-GpuVMAgent -Reason control (the person takes control).
    The drag must answer with the take-over error within ~100 ms of the suspend, and in the machine the left button
    must be down only until then (a pointer log runs inside it with exec.run, on its own clock).

.DESCRIPTION
    Elevated PowerShell. Paint should be open on the machine (run.ps1 -Name <machine> opens it). -Center is the
    spiral's center in screenshot pixels of a 1280-wide screenshot (default: the middle). Saves out\cancel.png and
    prints/returns the timings. Afterwards the machine is resumed and released.
    Why not Invoke-GpuVMAgent: the person's own requests (module/app) aren't an agent's work, so taking control never
    cancels them (the broker cancels only agent sessions' requests); only an MCP session reproduces the take-over.
#>
param(
    [Parameter(Mandatory)][string]$Name,
    [string]$Exe = "$env:ProgramFiles\GpuVM\gpuvm.exe",
    [int[]]$Center,
    [int]$DurationMs = 10000,
    [int]$SuspendAfterMs = 2000,
    [string]$Out = (Join-Path $PSScriptRoot 'out')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM') -Force
New-Item -ItemType Directory -Force $Out | Out-Null

$psi = [Diagnostics.ProcessStartInfo]::new($Exe, '--mcp')
$psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$p = [Diagnostics.Process]::Start($psi)
$script:next = 0
function Rpc([string]$method, $params) {
    $script:next++
    $p.StandardInput.WriteLine((@{ jsonrpc = '2.0'; id = $script:next; method = $method; params = $params } | ConvertTo-Json -Depth 30 -Compress))
    $p.StandardInput.Flush()
    while ($true) {
        $line = $p.StandardOutput.ReadLine()
        if ($null -eq $line) { throw "server closed: $($p.StandardError.ReadToEnd())" }
        $m = $line | ConvertFrom-Json
        if ($m.id -eq $script:next) { return $m }
    }
}
function Tool([string]$tool, $arguments) {
    $r = Rpc 'tools/call' @{ name = $tool; arguments = $arguments }
    $text = ($r.result.content | Where-Object type -eq 'text' | ForEach-Object text) -join "`n"
    [pscustomobject]@{ isError = [bool]$r.result.isError; text = $text }
}

try {
    $null = Rpc 'initialize' @{ protocolVersion = '2025-11-25'; capabilities = @{}; clientInfo = @{ name = 'lab059'; version = '1' } }
    $p.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}'); $p.StandardInput.Flush()
    $take = Tool take_machine @{ machine = $Name; task = 'lab 059 take-over check' }
    if ($take.isError) { throw "take_machine: $($take.text)" }
    $shot = Tool screenshot @{ machine = $Name; maxWidth = 1280 }
    if ($shot.isError) { throw "screenshot: $($shot.text)" }
    if (-not $Center) { $Center = 640, 400 }
    $n = 1500; $turns = 6; $r = 150
    $path = @(0..($n - 1) | ForEach-Object { $t = $_ / ($n - 1); $a = 2 * [math]::PI * $turns * $t
        , @([int]($Center[0] + $r * $t * [math]::Cos($a)), [int]($Center[1] + $r * $t * [math]::Sin($a))) })

    # Inside the machine, the pointer every ~10 ms for the whole check (its own clock): when it stopped moving.
    $logger = 'Add-Type -AssemblyName System.Windows.Forms; $sw = [Diagnostics.Stopwatch]::StartNew(); $prev = ""; while ($sw.ElapsedMilliseconds -lt 12000) { $c = [System.Windows.Forms.Cursor]::Position; $b = [System.Windows.Forms.Control]::MouseButtons; $s = "$($c.X),$($c.Y),$b"; if ($s -ne $prev) { "$($sw.ElapsedMilliseconds),$s"; $prev = $s }; Start-Sleep -Milliseconds 10 }'
    $log = Start-ThreadJob -ArgumentList $Name, $logger, (Join-Path $PSScriptRoot '..\..\src\GpuVM') {
        param($n, $cmd, $module)
        Import-Module $module -Force
        (Invoke-GpuVMAgent -Name $n -Method exec.run -Params @{ file = 'powershell.exe'; args = @('-NoProfile', '-Command', $cmd) } -TimeoutSec 60).result.stdout
    }
    Start-Sleep 2
    # The person takes control from another thread, at SuspendAfterMs; it notes when the suspend returned.
    $job = Start-ThreadJob -ArgumentList $Name, $SuspendAfterMs, (Join-Path $PSScriptRoot '..\..\src\GpuVM') {
        param($n, $after, $module)
        Import-Module $module -Force
        Start-Sleep -Milliseconds $after
        $t0 = [DateTime]::UtcNow
        Suspend-GpuVMAgent -Name $n -Reason control -Message 'lab 059 take-over check' | Out-Null
        [pscustomobject]@{ start = $t0; done = [DateTime]::UtcNow }
    }
    $start = [DateTime]::UtcNow
    $drag = Tool drag @{ machine = $Name; path = $path; durationMs = $DurationMs }
    $end = [DateTime]::UtcNow
    $s = Receive-Job $job -Wait -AutoRemoveJob
    $moves = @((Receive-Job $log -Wait -AutoRemoveJob) -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $f = $_ -split ','; [pscustomobject]@{ ms = [int]$f[0]; x = [int]$f[1]; y = [int]$f[2]; b = $f[3] } })
    $down = @($moves | Where-Object b -eq 'Left')
    $cap = Invoke-GpuVMAgent -Name $Name -Method screen.capture -Params @{ maxW = 1920; format = 'png' } -TimeoutSec 30
    if ($cap.ok) { Copy-Item -LiteralPath $cap.blobPath -Destination (Join-Path $Out 'cancel.png') -Force }
    $res = [pscustomobject]@{
        # in the machine: how long the left button was down (≈ suspendAtMs) and where the pointer last was
        guestPressedMs = if ($down) { $down[-1].ms - $down[0].ms } else { 0 }
        guestStoppedAfterReleaseMs = if ($down) { $moves[-1].ms - $down[-1].ms } else { 0 }
        guestLast = if ($moves) { "$($moves[-1].x),$($moves[-1].y),$($moves[-1].b)" }
        dragMs = [int]($end - $start).TotalMilliseconds
        suspendAtMs = [int]($s.start - $start).TotalMilliseconds
        answerAfterSuspendMs = [int]($end - $s.done).TotalMilliseconds
        isError = $drag.isError
        text = $drag.text
    }
    $res | Format-List | Out-String | Write-Host
    $res | ConvertTo-Json | Set-Content (Join-Path $Out 'cancel.json') -Encoding utf8
    $res
} finally {
    Resume-GpuVMAgent -Name $Name | Out-Null
    try { $null = Tool release_machine @{ machine = $Name } } catch { Write-Warning $_ }
    $p.StandardInput.Close()
    if (-not $p.WaitForExit(3000)) { $p.Kill() }
}
