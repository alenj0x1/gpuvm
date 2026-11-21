# Lab 063: the guest agent's screenshots under the lab's load. Starts race.ps1 (the load, and the WGC probe without
# the fix as a control) in another process, takes a screen.capture every -EveryMs through GpuVM's module (keeps the
# agent's capture open, so it checks every frame), and reports the agent's unfinished-frame counters from the last
# screenshot: frames finished by copying again, taken as they were, or seen while the check was off. Run elevated,
# with the GpuVM service running. Out: out\<Label>-agent.json (+ race.ps1's out\<Label>\)
param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Label, [int]$Seconds = 60, [string]$Load = 'videochurn', [int]$EveryMs = 500)
$ErrorActionPreference = 'Stop'
Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
$out = Join-Path $PSScriptRoot 'out'
$race = Start-Process pwsh -ArgumentList '-NoProfile', '-File', (Join-Path $PSScriptRoot 'race.ps1'), '-Name', $Name, '-Label', $Label, '-Seconds', $Seconds, '-Delays', 'fast2', '-Pool', '1', '-Load', $Load, '-Prio', 'rt', '-Cursor', '-ProbeFirst' -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $out "$Label-race.txt")
$shots = 0; $failed = 0; $last = $null; $ms = @()
$w = [Diagnostics.Stopwatch]::StartNew()
try {
    while (-not $race.HasExited -and $w.Elapsed.TotalSeconds -lt $Seconds + 120) {
        $r = Invoke-GpuVMAgent -Name $Name -Method screen.capture -Params @{ format = 'webp'; maxW = 640; maxH = 360 }
        if ($r.ok) { $shots++; $last = $r.result; $ms += $r.result.ms.grab } else { $failed++ }
        Start-Sleep -Milliseconds $EveryMs
    }
}
finally { if (-not $race.HasExited) { $race.WaitForExit(120000) | Out-Null } }
$probe = Get-Content (Join-Path $out "$Label\result.json") -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
$grab = @($ms | Sort-Object)
$row = [ordered]@{
    label = $Label; at = (Get-Date).ToString('s'); shots = $shots; failed = $failed
    grabMsMedian = if ($grab) { $grab[[int][Math]::Floor($grab.Count / 2)] } else { $null }
    agent = $last.unfinishedFrames
    probeUnfinishedPerMin = if ($probe) { [math]::Round($probe.alpha0Frames / [math]::Max(1, $probe.seconds) * 60, 1) } else { $null }
}
$row | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $out "$Label-agent.json")
"$Label  shots=$shots failed=$failed grab median=$($row.grabMsMedian) ms | agent: $($row.agent | ConvertTo-Json -Compress) | probe without fix: $($row.probeUnfinishedPerMin) unfinished/min"
