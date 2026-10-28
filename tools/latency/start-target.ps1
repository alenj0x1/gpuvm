# Copies the latency target into the VM and starts it in the signed-in user's session.
# Run as administrator (PowerShell Direct). The guest's Windows password must be saved in GpuVM.
param(
    [Parameter(Mandatory)][string]$Name,
    [int]$Minutes = 20
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$vm = Get-LatencyVM -Name $Name

$code = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'target.ps1')
Invoke-Command -VMName $Name -Credential $vm.Guest -ArgumentList $code, $Minutes -ScriptBlock {
    param($code, $minutes)
    $script = 'C:\GpuVM\latency-target.ps1'
    # UTF-8 with BOM so Windows PowerShell 5.1 reads it correctly.
    [IO.File]::WriteAllText($script, $code, [Text.UTF8Encoding]::new($true))
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object CommandLine -like '*latency-target.ps1*' |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    $user = (Get-CimInstance Win32_ComputerSystem).UserName
    if (-not $user) { throw 'Nobody is signed in on the VM display.' }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Minutes $minutes"
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName 'GpuVM-LatencyTarget' -Action $action -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName 'GpuVM-LatencyTarget'
    Start-Sleep -Seconds 3
    Unregister-ScheduledTask -TaskName 'GpuVM-LatencyTarget' -Confirm:$false
    "started for $minutes min as $user"
}
