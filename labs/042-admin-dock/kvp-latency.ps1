# Lab 042, part 1: how long a host -> guest Hyper-V data exchange (KVP) item takes to reach the guest, and the guest's
# answer to come back, against today's PowerShell Direct + one-time SYSTEM task path (~5 s, lab 026).
# Writes a host item (Msvm_VirtualSystemManagementService.AddKvpItems/ModifyKvpItems, source 0) that a probe loop in the
# guest polls under HKLM\SOFTWARE\Microsoft\Virtual Machine\External every 5 ms; the probe echoes it under ...\Guest,
# which the host reads like Get-GuestAdminPrompt does. Guest timestamps are mapped to the host clock with the offset of
# the fastest of several PowerShell Direct round trips. Leaves nothing behind (both items removed in finally).
# Run elevated: pwsh -File labs/042-admin-dock/kvp-latency.ps1 -Name win-gpu [-Count 40]
param(
    [string]$Name = 'win-gpu',
    [int]$Count = 40,
    [string]$OutDir = (Join-Path $PSScriptRoot "out\kvp-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null
. (Join-Path $PSScriptRoot '..\..\tools\latency\common.ps1')
. (Join-Path $PSScriptRoot 'kvp-host.ps1')
$vm = Get-VM -Name $Name
if ($vm.State -ne 'Running') { throw "La VM '$Name' está apagada." }
$guest = (Get-LatencyVM -Name $Name).Guest
$session = New-PSSession -VMName $Name -Credential $guest
$probeKey = 'GpuVMLab042'
$results = [System.Collections.Generic.List[object]]::new()
try {
    # Clock offset (guest - host) from the fastest round trip.
    $best = $null
    for ($i = 0; $i -lt 8; $i++) {
        $t0 = [DateTime]::UtcNow.Ticks
        $g = Invoke-Command -Session $session -ScriptBlock { [DateTime]::UtcNow.Ticks }
        $t1 = [DateTime]::UtcNow.Ticks
        if (-not $best -or ($t1 - $t0) -lt $best.rtt) { $best = @{ rtt = $t1 - $t0; offset = $g - ($t0 + $t1) / 2 } }
    }
    "offset {0:N1} ms (rtt {1:N1} ms)" -f ($best.offset / 1e4), ($best.rtt / 1e4)

    $job = Invoke-Command -Session $session -AsJob -ArgumentList $probeKey, ($Count * 4 + 30) -ScriptBlock {
        param($key, $seconds)
        $ext = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\External'
        $gst = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest'
        $last = $null
        $seen = [System.Collections.Generic.List[string]]::new()
        $end = [DateTime]::UtcNow.AddSeconds($seconds)
        while ([DateTime]::UtcNow -lt $end) {
            $v = (Get-ItemProperty -Path $ext -Name $key -ErrorAction SilentlyContinue).$key
            if ($v -and $v -ne $last) {
                $last = $v
                $seen.Add("$v;$([DateTime]::UtcNow.Ticks)")
                Set-ItemProperty -Path $gst -Name $key -Value $v -Type String
                if ($v -eq 'stop') { break }
            }
            Start-Sleep -Milliseconds 5
        }
        Remove-ItemProperty -Path $gst -Name $key -ErrorAction SilentlyContinue
        $seen
    }
    Start-Sleep -Seconds 2
    $added = $false
    for ($n = 1; $n -le $Count; $n++) {
        $value = "v$n-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        $sent = [DateTime]::UtcNow.Ticks
        $call = Measure-Command { Set-HostKvpItem -VMName $Name -Key $probeKey -Value $value -Add:(-not $added) }
        $added = $true
        $back = $null
        $reads = 0
        while (([DateTime]::UtcNow.Ticks - $sent) -lt 10e7) {
            $reads++
            if ((Get-GuestKvpItem -VMName $Name -Key $probeKey) -eq $value) { $back = [DateTime]::UtcNow.Ticks; break }
            Start-Sleep -Milliseconds 20
        }
        $results.Add([pscustomobject]@{ n = $n; value = $value; sent = $sent; callMs = [math]::Round($call.TotalMilliseconds, 1); backMs = if ($back) { [math]::Round(($back - $sent) / 1e4, 1) } else { $null }; reads = $reads })
        Start-Sleep -Milliseconds (Get-Random -Minimum 300 -Maximum 800)
    }
    Set-HostKvpItem -VMName $Name -Key $probeKey -Value 'stop'
    $seen = Receive-Job $job -Wait -AutoRemoveJob
    foreach ($line in $seen) {
        $v, $ticks = $line -split ';'
        $r = $results | Where-Object value -eq $v
        if ($r) { $r | Add-Member -NotePropertyName guestMs -NotePropertyValue ([math]::Round(([int64]$ticks - $best.offset - $r.sent) / 1e4, 1)) }
    }
}
finally {
    try { Remove-HostKvpItem -VMName $Name -Key $probeKey } catch {}
    Invoke-Command -Session $session -ArgumentList $probeKey -ScriptBlock { param($k) Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest' -Name $k -ErrorAction SilentlyContinue } -ErrorAction SilentlyContinue
    Remove-PSSession $session -ErrorAction SilentlyContinue
    $results | ConvertTo-Json | Set-Content (Join-Path $OutDir 'samples.json')
}
function Summary($values) {
    $v = @($values | Where-Object { $null -ne $_ } | Sort-Object)
    if (-not $v.Count) { return 'n/a' }
    "n={0} mean={1:N0} median={2:N0} p95={3:N0} max={4:N0} ms" -f $v.Count, ($v | Measure-Object -Average).Average, $v[[int][math]::Floor(($v.Count - 1) / 2)], $v[[int][math]::Ceiling(0.95 * $v.Count) - 1], $v[-1]
}
"host call (Add/ModifyKvpItems): $(Summary $results.callMs)"
"host -> guest (seen by guest):  $(Summary ($results | ForEach-Object { $_.guestMs }))"
"round trip (echo read on host): $(Summary $results.backMs)"
"missing echoes: $(@($results | Where-Object { -not $_.backMs }).Count)"
