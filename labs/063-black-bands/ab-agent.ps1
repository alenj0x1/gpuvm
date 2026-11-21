# Lab 063: the guest agent's unfinished-frame check, on against off, in turns (agent-swap.ps1 sets the off flag and
# restarts the agent, so its capture reopens and reads the flag), each an agent-shots.ps1 run. Checks that the agent's
# processes are new and the flag is what the arm says before measuring. One line per run in out\ab-agent.jsonl.
# Run elevated.
param([Parameter(Mandatory)][string]$Name, [int]$Rounds = 2, [int]$Seconds = 60, [string]$Load = 'videochurn', [string]$Tag = 'ag')
. (Join-Path $PSScriptRoot 'common.ps1')
$cred = Get-Lab063Cred $Name
$log = Join-Path $PSScriptRoot 'out\ab-agent.jsonl'
foreach ($round in 1..$Rounds) {
    foreach ($arm in 'on', 'off') {
        $label = "$Tag-$round-$arm"
        $before = Get-Date
        $swap = @{ Name = $Name }
        if ($arm -eq 'off') { $swap.CheckOff = $true }
        & (Join-Path $PSScriptRoot 'agent-swap.ps1') @swap | Out-Null
        $state = Invoke-Command -VMName $Name -Credential $cred {
            [pscustomobject]@{
                started = @(Get-Process gpuvm-agent | ForEach-Object StartTime | Sort-Object)[0]
                off     = Test-Path 'C:\Program Files\GpuVM Agent\frame-check-off.txt'
            }
        }
        if ($state.off -ne ($arm -eq 'off')) { throw "$label`: the off flag is $($state.off)" }
        $summary = & (Join-Path $PSScriptRoot 'agent-shots.ps1') -Name $Name -Label $label -Seconds $Seconds -Load $Load
        $row = Get-Content (Join-Path $PSScriptRoot "out\$label-agent.json") -Raw | ConvertFrom-Json
        [ordered]@{ label = $label; arm = $arm; agentStarted = $state.started; agentRestarted = $state.started -ge $before.AddSeconds(-60); shots = $row.shots; grabMs = $row.grabMsMedian; agent = $row.agent; probePerMin = $row.probeUnfinishedPerMin } |
            ConvertTo-Json -Compress -Depth 4 | Add-Content $log
        $summary
    }
}
