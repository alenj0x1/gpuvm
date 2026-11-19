# Lab 051: runs the host-side harness against the guest agent in the lab VM. Takes the shared lab lock, registers
# the agent's service GUID on the host if nobody did (removed again at the end only if this lab added it), runs the
# scenarios and writes out\run-<time>\results.jsonl plus sample screenshots. Run elevated after prepare.ps1.
param(
    [string]$Name = 'agent051',
    [string]$Scenarios = 'info,capture,latency,uia,exec,files,secure,elevated,abuse,acl,errorbox,reboot',
    [string]$Me = 'agent-guest',
    # seconds to wait for the listener name when a broker under test holds it
    [int]$WaitBind = 0
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'
$run = Join-Path $out ('run-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
& (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What "lab 051: guest agent harness on $Name" -Me $Me
if ($LASTEXITCODE -ne 0) { throw 'no lock' }
$reg = $null
try {
    if ((Get-VM -Name $Name).State -ne 'Running') { Start-VM -Name $Name }
    $reg = & (Join-Path $PSScriptRoot 'service.ps1')
    $reg
    $vmId = (Get-VM -Name $Name).Id.Guid
    & (Join-Path $PSScriptRoot 'harness\target\release\harness.exe') serve --secret (Join-Path $out 'secret.bin') --vm $vmId --name $Name `
        --out $run --psd (Join-Path $PSScriptRoot 'psd.ps1') --scenarios $Scenarios --wait-bind $WaitBind
    "results: $run"
}
finally {
    if ($reg -like 'registered*') { & (Join-Path $PSScriptRoot 'service.ps1') -Remove }
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    "lock released $(Get-Date -Format HH:mm:ss)"
}
