# Turns the lab VM into the shared template `agent-tpl`: removes the lab's guest-side files, runs install.ps1
# -PrepareTemplate (no secret, no logs: a template never carries a secret), checks that, shuts the VM down and saves
# it with New-GpuVMTemplate. Stops at the first error. Takes the lab lock (the disk copy is heavy I/O).
param([string]$Name = 'agent051', [string]$Template = 'agent-tpl', [string]$Me = 'agent-guest', [switch]$LockHeld)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
if (-not $LockHeld) {
    & (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What "lab 051: template $Template from $Name (disk copy)" -Me $Me
    if ($LASTEXITCODE -ne 0) { throw 'no lock' }
}
try {
    $c = Import-Clixml (Join-Path $PSScriptRoot 'out\guest.xml')
    if ((Get-VM -Name $Name).State -ne 'Running') { Start-VM -Name $Name; & (Join-Path $root 'labs\047-hvsocket\wait-ready.ps1') -Name $Name -MaxMinutes 10 | Out-Null }
    $install = Get-Content (Join-Path $root 'guest\agent\install.ps1') -Raw
    $r = Invoke-Command -VMName $Name -Credential $c {
        param($text)
        Remove-Item C:\ProgramData\GpuVMLab051 -Recurse -Force -ErrorAction SilentlyContinue
        & ([scriptblock]::Create($text)) -PrepareTemplate
    } -ArgumentList $install
    $left = Invoke-Command -VMName $Name -Credential $c { @(Get-ChildItem C:\ProgramData\GpuVM\Agent -Force | ForEach-Object Name) -join ',' }
    "prepare: $($r | ConvertTo-Json -Compress); left in the data folder: '$left'"
    if ($left -match 'secret') { throw 'the secret is still there: no template' }
    $t = Measure-Command { New-GpuVMTemplate -Name $Template -VMName $Name -ShutdownIfRunning -Confirm:$false }
    "template $Template in $([int]$t.TotalSeconds) s"
}
finally {
    if (-not $LockHeld) { Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue }
    "lock released $(Get-Date -Format HH:mm:ss)"
}
