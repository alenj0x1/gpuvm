# Lab 063 shared bits: the machine's guest credential (as GpuVM keeps it) and a PowerShell Direct session. Dot-source.
$ErrorActionPreference = 'Stop'
$script:Lab063Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $script:Lab063Root 'src\GpuVM\GpuVM.psd1') -Force
function Get-Lab063Cred([string]$Name) {
    # the repo's module: with the installed one also loaded (agent-swap.ps1), Get-Module returns both
    $m = Get-Module GpuVM | Where-Object { $_.Path -like "$script:Lab063Root*" } | Select-Object -First 1
    $state = & $m { param($n) Get-GpuVMState -Name $n } $Name
    & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
}
