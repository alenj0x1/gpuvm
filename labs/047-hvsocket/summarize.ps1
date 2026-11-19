# Summarizes a run.ps1 output folder: p50/p95/p99 per measure and direction, pooled over rounds.
param([Parameter(Mandatory)][string]$Dir)
function P([double[]]$v, [double]$p) { $s = $v | Sort-Object; $s[[int][math]::Round(($p / 100) * ($s.Count - 1))] }
$rows = foreach ($side in 'g2h', 'h2g') {
    $files = Get-ChildItem $Dir -Filter "$side-r*.json"
    $all = $files | ForEach-Object { Get-Content $_ -Raw | ConvertFrom-Json }
    $lat = $all | ForEach-Object { $_.latency100.us }
    $con = $all | ForEach-Object { $_.connect.us }
    $first = $all | ForEach-Object { $_.connect.firstRoundTripUs }
    [pscustomobject]@{ dir = $side; measure = '100 B round trip (us)'; n = $lat.Count; p50 = P $lat 50; p95 = P $lat 95; p99 = P $lat 99 }
    [pscustomobject]@{ dir = $side; measure = 'connect (us)'; n = $con.Count; p50 = P $con 50; p95 = P $con 95; p99 = P $con 99 }
    [pscustomobject]@{ dir = $side; measure = 'first round trip on new conn (us)'; n = $first.Count; p50 = P $first 50; p95 = P $first 95; p99 = P $first 99 }
    foreach ($mb in 1, 2, 4) {
        foreach ($d in 'up', 'down') {
            $ms = $all | ForEach-Object { ($_.frames | Where-Object { $_.mb -eq $mb -and $_.dir -eq $d }).ms }
            $p50 = P $ms 50
            [pscustomobject]@{ dir = $side; measure = "$mb MB $d (ms) [MB/s at p50 = $([math]::Round($mb / ($p50 / 1000)))]"; n = $ms.Count; p50 = $p50; p95 = P $ms 95; p99 = P $ms 99 }
        }
    }
}
$ps = Get-ChildItem $Dir -Filter 'psdirect-r*.json' | ForEach-Object { (Get-Content $_ -Raw | ConvertFrom-Json).ms }
$rows += [pscustomobject]@{ dir = 'psdirect'; measure = 'open session 100 B round trip (ms)'; n = $ps.Count; p50 = P $ps 50; p95 = P $ps 95; p99 = P $ps 99 }
$psn = Get-ChildItem $Dir -Filter 'psdirect-new-r*.json' | ForEach-Object { (Get-Content $_ -Raw | ConvertFrom-Json).ms }
$rows += [pscustomobject]@{ dir = 'psdirect'; measure = 'new session + 100 B (ms)'; n = $psn.Count; p50 = P $psn 50; p95 = P $psn 95; p99 = P $psn 99 }
$rows | Format-Table -AutoSize | Out-String -Width 200
$rows | ConvertTo-Json | Set-Content (Join-Path $Dir 'summary.json')
