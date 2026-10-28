# Closes the latency target in the VM (it also closes itself after its -Minutes). Run as administrator.
param([Parameter(Mandatory)][string]$Name)
. (Join-Path $PSScriptRoot 'common.ps1')
$vm = Get-LatencyVM -Name $Name
Invoke-Command -VMName $Name -Credential $vm.Guest -ScriptBlock {
    $targets = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object CommandLine -like '*latency-target*'
    $targets | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Get-ScheduledTask -TaskName '*latency*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
    "closed $(@($targets).Count) target(s)"
}
