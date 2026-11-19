# Lab 047 part A: Hyper-V socket latency, throughput, connect time and peer identity, both directions, against an
# open PowerShell Direct session doing the same 100-byte round trip. Rounds interleave the variants.
#   guest->host : host listens on HV_GUID_CHILDREN, guest dials HV_GUID_PARENT (hvlab bench in the guest)
#   host->guest : guest listens on HV_GUID_WILDCARD, host dials the VM's Id (hvlab bench on the host)
#   psdirect    : Invoke-Command on an already-open session, 100-byte string in, same string out
# Nothing is installed in the guest: hvlab.exe goes to C:\GpuVMLab047 (removed in finally); the guest listener lives
# only while the PowerShell Direct session does. Run elevated:  pwsh -File labs/047-hvsocket/run.ps1 -Name win-gpu
param(
    [string]$Name = 'win-gpu',
    [int]$Rounds = 2,
    [int]$Lat = 600,
    [int]$Frames = 60,
    [int]$PsCount = 500,
    [string]$Service = 'b1c0a047-6a5e-4c4b-9e47-047047047047',
    [string]$OutDir = (Join-Path $PSScriptRoot "out\run-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
. (Join-Path $root 'tools\latency\common.ps1')
New-Item -ItemType Directory -Force $OutDir | Out-Null
$exe = Join-Path $PSScriptRoot 'hvlab\target\release\hvlab.exe'
if (-not (Test-Path $exe)) { throw 'Build first: cargo build --release in labs/047-hvsocket/hvlab' }
$vmObj = Get-VM -Name $Name
if ($vmObj.State -ne 'Running') { throw "La VM '$Name' está apagada." }
$vmId = $vmObj.Id.Guid
& (Join-Path $PSScriptRoot 'service.ps1') -Guid $Service
$cred = (Get-LatencyVM -Name $Name).Guest
$sess = New-PSSession -VMName $Name -Credential $cred
$hostListener = $null
$summary = [ordered]@{ vm = $Name; vmId = $vmId; started = (Get-Date).ToString('o'); rounds = @() }
try {
    Invoke-Command -Session $sess { New-Item -ItemType Directory -Force C:\GpuVMLab047 | Out-Null }
    Copy-Item $exe -ToSession $sess -Destination C:\GpuVMLab047\hvlab.exe -Force

    $hostLog = Join-Path $OutDir 'host-listener.jsonl'
    $hostListener = Start-Process $exe -ArgumentList 'listen', '--bind', 'children', '--service', $Service, '--log', $hostLog -PassThru -WindowStyle Hidden
    # Guest listener, started through the open session (dies with it).
    Invoke-Command -Session $sess -ArgumentList $Service {
        param($svc)
        Get-Process hvlab -ErrorAction SilentlyContinue | Stop-Process -Force
        $global:gl = Start-Process C:\GpuVMLab047\hvlab.exe -ArgumentList 'listen', '--bind', 'wildcard', '--service', $svc, '--log', 'C:\GpuVMLab047\guest-listener.jsonl' -PassThru -WindowStyle Hidden
    }
    Start-Sleep -Seconds 1

    for ($round = 1; $round -le $Rounds; $round++) {
        $r = [ordered]@{ round = $round }
        # guest -> host
        $g2h = Invoke-Command -Session $sess -ArgumentList $Service, $Lat, $Frames {
            param($svc, $lat, $frames)
            $o = "C:\GpuVMLab047\bench-g2h.json"
            $err = & C:\GpuVMLab047\hvlab.exe bench --vm parent --service $svc --lat $lat --frames $frames --connects 60 --out $o 2>&1
            [pscustomobject]@{ json = Get-Content $o -Raw; log = ($err -join "`n") }
        }
        Set-Content (Join-Path $OutDir "g2h-r$round.json") $g2h.json
        "round $round guest->host:`n$($g2h.log)"
        # host -> guest
        $o = Join-Path $OutDir "h2g-r$round.json"
        $log = & $exe bench --vm $vmId --service $Service --lat $Lat --frames $Frames --connects 60 --out $o 2>&1
        "round $round host->guest:`n$($log -join "`n")"
        # PowerShell Direct, open session, same 100-byte round trip
        $payload = 'x' * 100
        $ps = [System.Collections.Generic.List[double]]::new()
        for ($i = 0; $i -lt 20; $i++) { $null = Invoke-Command -Session $sess -ArgumentList $payload { param($p) $p } }
        for ($i = 0; $i -lt $PsCount; $i++) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $back = Invoke-Command -Session $sess -ArgumentList $payload { param($p) $p }
            $sw.Stop()
            if ($back -ne $payload) { throw 'psdirect echo mismatch' }
            $ps.Add($sw.Elapsed.TotalMilliseconds)
        }
        $sorted = $ps | Sort-Object
        "round $round psdirect 100B: p50 {0:N2} ms p95 {1:N2} ms" -f $sorted[[int](0.5 * ($sorted.Count - 1))], $sorted[[int](0.95 * ($sorted.Count - 1))]
        Set-Content (Join-Path $OutDir "psdirect-r$round.json") (@{ ms = @($ps) } | ConvertTo-Json -Compress)
        # PowerShell Direct, new session each time (what GpuVM does today for one-off commands)
        $fresh = [System.Collections.Generic.List[double]]::new()
        for ($i = 0; $i -lt 10; $i++) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $null = Invoke-Command -VMName $Name -Credential $cred -ArgumentList $payload { param($p) $p }
            $sw.Stop(); $fresh.Add($sw.Elapsed.TotalMilliseconds)
        }
        Set-Content (Join-Path $OutDir "psdirect-new-r$round.json") (@{ ms = @($fresh) } | ConvertTo-Json -Compress)
        "round $round psdirect new session: median {0:N0} ms" -f (($fresh | Sort-Object)[5])
    }
}
finally {
    if ($hostListener) { Stop-Process -Id $hostListener.Id -Force -ErrorAction SilentlyContinue }
    try {
        $gl = Invoke-Command -Session $sess {
            Get-Process hvlab -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep -Milliseconds 300
            Get-Content C:\GpuVMLab047\guest-listener.jsonl -ErrorAction SilentlyContinue
        }
        Set-Content (Join-Path $OutDir 'guest-listener.jsonl') $gl
        Invoke-Command -Session $sess {
            Remove-Item C:\GpuVMLab047 -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch { Write-Warning "guest cleanup: $_" }
    Remove-PSSession $sess -ErrorAction SilentlyContinue
    $summary.finished = (Get-Date).ToString('o')
    Set-Content (Join-Path $OutDir 'meta.json') ($summary | ConvertTo-Json)
    "out: $OutDir"
}
