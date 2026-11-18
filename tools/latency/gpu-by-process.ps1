# The host GPU's 3D engine use per process, averaged over -Seconds (Windows' GPU Engine counters): who draws, and how
# much. -Match keeps the processes whose name matches.
#   tools/latency/gpu-by-process.ps1 [-Seconds 4] [-Match 'chrome|webview']
param([double]$Seconds = 4, [string]$Match = '.')
$sums = @{}
$n = [math]::Max(1, [int]$Seconds)
foreach ($i in 1..$n) {
    $c = Get-Counter '\GPU Engine(*engtype_3d)\Utilization Percentage' -ErrorAction SilentlyContinue
    foreach ($s in $c.CounterSamples) {
        if ($s.InstanceName -match 'pid_(\d+)_') { $p = [int]$Matches[1]; $sums[$p] = ($sums[$p] ?? 0) + $s.CookedValue }
    }
}
$sums.GetEnumerator() | ForEach-Object {
    $proc = Get-Process -Id $_.Key -ErrorAction SilentlyContinue
    [pscustomobject]@{ Process = if ($proc) { $proc.Name } else { "pid $($_.Key)" }; Pid = $_.Key; Pct = [math]::Round($_.Value / $n, 1) }
} | Where-Object { $_.Pct -ge 0.3 -and $_.Process -match $Match } | Sort-Object Pct -Descending
