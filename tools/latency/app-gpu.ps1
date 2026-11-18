# How much of the host GPU the GpuVM app's own window takes (its WebView's 3D engine), averaged over -Seconds.
#   tools/latency/app-gpu.ps1 [-Seconds 4]
param([double]$Seconds = 4)
$app = Get-Process gpuvm -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $app) { return 'GpuVM is not running' }
# Its WebView processes: children (and grandchildren) of gpuvm.exe.
$all = Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'"
$ids = [System.Collections.Generic.HashSet[int]]::new()
$frontier = @($app.Id)
while ($frontier) {
    $next = @($all | Where-Object { $frontier -contains $_.ParentProcessId -and $ids.Add([int]$_.ProcessId) } | ForEach-Object { [int]$_.ProcessId })
    $frontier = $next
}
$samples = [math]::Max(1, [int]$Seconds)
$values = foreach ($i in 1..$samples) {
    $c = Get-Counter '\GPU Engine(*engtype_3d)\Utilization Percentage' -ErrorAction SilentlyContinue
    $sum = 0.0
    foreach ($s in $c.CounterSamples) { if ($s.InstanceName -match 'pid_(\d+)_' -and $ids.Contains([int]$Matches[1])) { $sum += $s.CookedValue } }
    $sum
}
$gpu = [int](nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | Select-Object -First 1)
"app 3D {0:N1} % (whole GPU {1} %)" -f (($values | Measure-Object -Average).Average), $gpu
