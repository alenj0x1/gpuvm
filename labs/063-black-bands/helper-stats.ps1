# Lab 063: the helper's counters over every helper log written since -Since (Sunshine restarts the helper when a
# viewer connects or leaves, so one session can span logs): lab063 verification (frames, glitches, src_diff, alpha0;
# the last line of each log) and the unfinished-frame check (sums of its 15 s lines). Run elevated.
param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][datetime]$Since)
. (Join-Path $PSScriptRoot 'common.ps1')
$cred = Get-Lab063Cred $Name
Invoke-Command -VMName $Name -Credential $cred -ArgumentList $Since {
    param($since)
    $user = (Get-CimInstance Win32_ComputerSystem).UserName.Split('\')[-1]
    $logs = @(Get-ChildItem "C:\Users\$user\AppData\Roaming\Sunshine\wgc-helper" -Filter *.log | Where-Object LastWriteTime -ge $since.AddSeconds(-5) | Sort-Object Name)
    $r = [ordered]@{ logs = $logs.Count; frames = 0; glitches = 0; srcDiff = 0; alpha0 = 0; check = ''; finished = 0; takenAsIs = 0; maxWaitUs = 0 }
    foreach ($f in $logs) {
        $lines = @(Get-Content $f.FullName -ErrorAction SilentlyContinue)
        $last = $lines | Where-Object { $_ -match 'lab063: frames=(\d+) glitches=(\d+) src_diff=(\d+) alpha0=(\d+)' } | Select-Object -Last 1
        if ($last -and $last -match 'lab063: frames=(\d+) glitches=(\d+) src_diff=(\d+) alpha0=(\d+)') {
            $r.frames += [int]$Matches[1]; $r.glitches += [int]$Matches[2]; $r.srcDiff += [int]$Matches[3]; $r.alpha0 += [int]$Matches[4]
        }
        foreach ($l in $lines) {
            if ($l -match 'unfinished-frame check (on|off)') { $r.check = $Matches[1] }
            if ($l -match 'finished=(\d+) taken_as_is=(\d+) avg_wait_us=\d+ max_wait_us=(\d+)') {
                $r.finished += [int]$Matches[1]; $r.takenAsIs += [int]$Matches[2]; $r.maxWaitUs = [Math]::Max($r.maxWaitUs, [int]$Matches[3])
            }
        }
    }
    [pscustomobject]$r
} | Select-Object logs, frames, glitches, srcDiff, alpha0, check, finished, takenAsIs, maxWaitUs
