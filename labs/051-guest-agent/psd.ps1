# Runs one PowerShell command inside the lab VM as its administrator (PowerShell Direct), for the harness:
# guest-side actions the agent itself must never be able to do (kill a UAC prompt, change an ACL, restart).
param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Command)
$ErrorActionPreference = 'Stop'
$cred = Import-Clixml (Join-Path $PSScriptRoot 'out\guest.xml')
Invoke-Command -VMName $Name -Credential $cred -ScriptBlock ([scriptblock]::Create($Command)) | Out-String -Width 400
