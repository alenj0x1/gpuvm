# Lab 063: the fix against no fix, end to end. Rounds of (check on, check off) in turns with the same helper build
# (the off flag), each a stream.ps1 run: what the stream showed, what the helper handed Sunshine (lab063 counters) and
# what the fix caught. One line per run in out\ab.jsonl. Run elevated.
param([Parameter(Mandatory)][string]$Name, [int]$Rounds = 3, [int]$Seconds = 60, [string]$Load = 'videochurn', [string]$Tag = 'ab')
$here = $PSScriptRoot
$log = Join-Path $here 'out\ab.jsonl'
foreach ($round in 1..$Rounds) {
    foreach ($arm in 'on', 'off') {
        $label = "$Tag-$round-$arm"
        $swap = @{ Name = $Name; Verify = $true }
        if ($arm -eq 'off') { $swap.CheckOff = $true }
        & (Join-Path $here 'helper-swap.ps1') @swap | Out-Null
        $summary = & (Join-Path $here 'stream.ps1') -Name $Name -Label $label -Seconds $Seconds -Load $Load
        $row = Get-Content (Join-Path $here "out\$label-stream.json") -Raw | ConvertFrom-Json
        $h = $row.helper
        [ordered]@{ label = $label; arm = $arm; at = $row.at; stream = $row.count; perMin = $row.perMin; movingFps = $row.movingFps; helper = $h; error = $row.error } |
            ConvertTo-Json -Compress | Add-Content $log
        "$label  stream=$($row.count) ($($row.perMin)/min) | helper out: glitches=$($h.glitches) alpha0=$($h.alpha0) srcDiff=$($h.srcDiff) of $($h.frames) | check=$($h.check) finished=$($h.finished) asIs=$($h.takenAsIs) maxWait=$($h.maxWaitUs)us $($row.error)"
    }
}
