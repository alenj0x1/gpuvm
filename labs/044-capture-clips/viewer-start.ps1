# Lab 044 helper: does a viewer started the way the latency labs start it (tools/latency Start-LatencyViewer, not
# inside the app) show a picture? Tries each tools folder given (each one starts the viewer next to it, ..\..\viewer),
# so a build can be compared with the repo's. Prints one line per try with the bridge's messages.
param(
    [Parameter(Mandatory)][string]$Name,
    [string[]]$Tools = @((Join-Path $PSScriptRoot '..\..\tools\latency')),
    [int]$TimeoutSec = 45
)
$ErrorActionPreference = 'Stop'
foreach ($t in $Tools) {
    $out = pwsh -NoProfile -Command @"
`$ErrorActionPreference = 'Stop'
. '$t\common.ps1'
`$vm = Get-LatencyVM -Name '$Name'
try { & `$vm.Module { param(`$a, `$c) Invoke-SunshineApi -Address `$a -Credential `$c -Method POST -Path '/api/apps/close' } `$vm.Address `$vm.Sunshine | Out-Null } catch { }
Start-Sleep -Seconds 2
`$state = & `$vm.Module { param(`$n) Get-GpuVMState -Name `$n } '$Name'
`$client = [ordered]@{}; foreach (`$k in `$state['config']['streaming']['client'].Keys) { `$client[`$k] = `$state['config']['streaming']['client'][`$k] }
`$client['displayMode'] = 'borderless'
`$arguments = & `$vm.Module { param(`$a, `$c) Get-MoonlightStreamArguments -Address `$a -Client `$c } `$vm.Address `$client
`$started = Get-Date
`$s = Start-LatencyViewer -Viewer gpuvm -Arguments `$arguments
`$ff = Wait-LatencyViewerFrame `$s -Since `$started -TimeoutSec $TimeoutSec
`$p = `$s.Process; `$p.Refresh()
`$exit = if (`$p.HasExited) { "exited `$(`$p.ExitCode)" } else { 'running' }
"RESULT firstFrame=`$ff viewer=`$exit hello=`$(`$s.Bridge.Hello) exe=`$(`$p.Path) events=`$(@(`$s.Bridge.Events.ToArray()) -join ' | ')"
"ARGS `$(`$arguments -join ' ')"
Stop-LatencyStream `$s -VM `$vm
"@ 2>&1
    $out | Where-Object { "$_" -match '^(RESULT|ARGS)|error|Error|GpuVM:' } | ForEach-Object { "$t :: $_" }
}
