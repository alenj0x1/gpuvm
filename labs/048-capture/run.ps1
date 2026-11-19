# Lab 048: screen capture from a helper in the signed-in user's session (started from SYSTEM with WTSQueryUserToken +
# CreateProcessAsUser). Parts:
#   bench   : DXGI Desktop Duplication vs Windows.Graphics.Capture, per-step time and lossless sizes (PNG fast /
#             balanced, lossless WebP) at 1920x1080 and fit into 1280x800; idle and while Sunshine streams; rounds
#             interleaved.
#   mode    : a watcher (dxgi, then wgc) while the host switches the guest display 1920x1080 -> 1366x768 -> 1920x1080.
#   secure  : a watcher while an administrator prompt (secure desktop) opens and is denied.
# Test VM only (it opens apps, changes the display, raises a UAC prompt). Run elevated:
#   pwsh -File labs/048-capture/run.ps1 -Name agentlab [-Part bench,mode,secure] [-Stream]
param(
    [Parameter(Mandatory)][string]$Name,
    [string[]]$Part = @('bench', 'mode', 'secure'),
    [int]$Rounds = 2,
    [int]$N = 30,
    [switch]$Stream,
    [string]$OutDir = (Join-Path $PSScriptRoot "out\run-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
)
$ErrorActionPreference = 'Stop'
if ($Name -eq 'win-gpu') { throw 'Test VM only.' }
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
. (Join-Path $root 'tools\latency\common.ps1')
. (Join-Path $PSScriptRoot 'guest.ps1')
New-Item -ItemType Directory -Force $OutDir | Out-Null
$labVm = Get-LatencyVM -Name $Name
$sess = New-PSSession -VMName $Name -Credential $labVm.Guest
function Save-Json([string]$file, $text) { Set-Content (Join-Path $OutDir $file) $text }
function Now { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

try {
    Install-GuestProbe -Session $sess
    $who = Invoke-GuestProbe -Session $sess -ProbeArgs 'whoami'
    "probe runs as: $($who.result)"
    Save-Json 'whoami.json' $who.result
    if (($who.result | ConvertFrom-Json).inputDesktop -ne 'Default') { throw 'The guest is not on its normal desktop (locked? prompt open?).' }
    Save-Json 'outputs.json' (Invoke-GuestProbe -Session $sess -ProbeArgs 'outputs').result

    # Scene: the same Notepad text and Explorer folder in every run, so the sizes compare.
    Invoke-Command -Session $sess { Get-ChildItem C:\Windows\System32 -Filter *.dll | Select-Object -First 120 Name, Length, LastWriteTime | Format-Table | Out-String -Width 120 | Set-Content C:\GpuVMLab048\scene.txt }
    Start-GuestApp -Session $sess -Exe 'C:\Windows\explorer.exe' -AppArgs 'C:\Windows' | Out-Null
    Start-Sleep -Seconds 2
    Start-GuestApp -Session $sess -Exe 'C:\Windows\System32\notepad.exe' -AppArgs 'C:\GpuVMLab048\scene.txt' | Out-Null
    Start-Sleep -Seconds 2

    if ('bench' -in $Part) {
        $phases = @('idle')
        if ($Stream) { $phases += 'stream' }
        for ($round = 1; $round -le $Rounds; $round++) {
            foreach ($phase in $phases) {
                $streamSession = $null
                if ($phase -eq 'stream') {
                    $since = Get-Date
                    # Moonlight already paired with the test VM (Connect-GpuVM -Pair once); 1080p60 like lab 041's baseline
                    $streamSession = Start-LatencyStream -VM $labVm -Variant ([pscustomobject]@{ Fps = 60; VSync = $true })
                    $vis = Wait-LatencyStreamVisible -Since $since -TimeoutSec 90
                    "stream visible after $vis s"
                    if ($vis -lt 0) { Write-Warning 'stream never showed video; skipping stream phase'; Stop-LatencyStream -Session $streamSession -VM $labVm; continue }
                    Start-Sleep -Seconds 3
                }
                foreach ($method in 'dxgi', 'wgc') {
                    $save = if ($round -eq 1 -and $phase -eq 'idle') { 'C:\GpuVMLab048\out' } else { $null }
                    $pa = @('capture', '--method', $method, '--n', "$N")
                    if ($save) { $pa += '--save', $save }
                    $r = Invoke-GuestProbe -Session $sess -ProbeArgs $pa
                    Save-Json "bench-$method-$phase-r$round.json" $r.result
                    $j = $r.result | ConvertFrom-Json
                    $s = $j.samples
                    if (-not $j.ok -or -not $s) { "{0} {1} r{2}: FAILED {3} (re-opens {4})" -f $method, $phase, $round, $j.error, $j.reopened; continue }
                    "{0} {1} r{2}: ok={3} {4} open {5} ms first {6} ms | readback p50 {7:N1} | png-fast full {8:N1} ms {9:N0} KB | small png-bal {10:N1} ms {11:N0} KB | small webp {12:N1} ms {13:N0} KB | fresh {14}/{15}" -f `
                        $method, $phase, $round, $j.ok, $j.error, $j.openMs, $j.firstFrameMs,
                        (($s.readbackMs | Sort-Object)[[int]($s.Count / 2)]),
                        (($s.pngFullFastMs | Sort-Object)[[int]($s.Count / 2)]), (($s.pngFullFastB | Sort-Object)[[int]($s.Count / 2)] / 1KB),
                        (($s.pngSmallBalMs | Sort-Object)[[int]($s.Count / 2)]), (($s.pngSmallBalB | Sort-Object)[[int]($s.Count / 2)] / 1KB),
                        (($s.webpSmallMs | Sort-Object)[[int]($s.Count / 2)]), (($s.webpSmallB | Sort-Object)[[int]($s.Count / 2)] / 1KB),
                        @($s | Where-Object fresh).Count, $s.Count
                    if ($save) {
                        foreach ($f in "$method-full.png", "$method-small.png", "$method-small.webp") {
                            Copy-Item -FromSession $sess "C:\GpuVMLab048\out\$f" -Destination (Join-Path $OutDir $f) -ErrorAction SilentlyContinue
                        }
                    }
                }
                if ($streamSession) { Stop-LatencyStream -Session $streamSession -VM $labVm }
            }
        }
    }

    if ('mode' -in $Part) {
        foreach ($method in 'dxgi', 'wgc') {
            $id = Start-GuestProbe -Session $sess -ProbeArgs 'watch', '--method', $method, '--seconds', '30'
            Start-Sleep -Seconds 6
            $marks = @()
            foreach ($res in '1366x768', '1920x1080') {
                $t = Now
                $r = & $labVm.Module { param($n, $c, $x) Set-GuestDisplayResolution -Name $n -Credential $c -Resolution $x -Fps 60 } $Name $labVm.Guest $res
                $marks += [pscustomobject]@{ t = $t; tDone = Now; resolution = $res; applied = "$($r.applied)" }
                "mode $method -> $res (call took $((Now) - $t) ms)"
                Start-Sleep -Seconds 8
            }
            $r = Receive-GuestProbe -Session $sess -Id $id -TimeoutSec 60
            Save-Json "mode-$method.jsonl" $r.result
            Save-Json "mode-$method-marks.json" ($marks | ConvertTo-Json)
            if (-not $r.result) { "watch $method returned nothing: launch=$($r.launch)" }
        }
    }

    if ('secure' -in $Part) {
        foreach ($method in 'dxgi', 'wgc') {
            $id = Start-GuestProbe -Session $sess -ProbeArgs 'watch', '--method', $method, '--seconds', '25'
            Start-Sleep -Seconds 5
            $t1 = Now
            & (Join-Path $root 'labs\042-admin-dock\raise-prompt.ps1') -Name $Name
            Start-Sleep -Seconds 8
            $t2 = Now
            & (Join-Path $root 'labs\042-admin-dock\raise-prompt.ps1') -Name $Name -Deny
            $r = Receive-GuestProbe -Session $sess -Id $id -TimeoutSec 60
            Save-Json "secure-$method.jsonl" $r.result
            Save-Json "secure-$method-marks.json" (@{ promptRaised = $t1; denied = $t2 } | ConvertTo-Json)
            "secure $method done"
            Start-Sleep -Seconds 3
        }
    }
}
finally {
    try { Remove-GuestProbe -Session $sess } catch { Write-Warning "cleanup: $_" }
    Remove-PSSession $sess -ErrorAction SilentlyContinue
    "out: $OutDir"
}
