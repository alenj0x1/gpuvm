# Under one lab lock: start the lab VM, wait until Windows is ready, check the sign-in cycle with real restarts
# (signin-cycle.ps1) and save the template (make-template.ps1). Stops at the first failure.
param([string]$Name = 'agent051', [string]$Me = 'agent-guest')
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
& (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What "lab 051: sign-in cycle + template agent-tpl on $Name" -Me $Me
if ($LASTEXITCODE -ne 0) { throw 'no lock' }
try {
    if ((Get-VM -Name $Name).State -ne 'Running') { Start-VM -Name $Name }
    & (Join-Path $root 'labs\047-hvsocket\wait-ready.ps1') -Name $Name -MaxMinutes 20 | Select-Object -Last 2
    if ($LASTEXITCODE -ne 0) { throw 'the VM never got ready' }
    & (Join-Path $PSScriptRoot 'signin-cycle.ps1') -Name $Name
    & (Join-Path $PSScriptRoot 'make-template.ps1') -Name $Name -LockHeld
}
finally {
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    "lock released $(Get-Date -Format HH:mm:ss)"
}
