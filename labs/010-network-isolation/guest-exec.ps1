# Runs a script inside the VM over PowerShell Direct and saves its output (lab helper, run elevated).
# pwsh -File guest-exec.ps1 -Script path\to\code.ps1 -OutFile path\to\result.txt
param(
    [Parameter(Mandatory)][string]$Script,
    [Parameter(Mandatory)][string]$OutFile,
    [string]$Name = (Get-VM | Where-Object Notes -like "Creada con GpuVM*" | Select-Object -First 1).Name
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$module = Get-Module GpuVM
try {
    $state = & $module { param($n) Get-GpuVMState -Name $n } $Name
    $guest = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state
    $code = Get-Content -Raw -LiteralPath $Script
    $output = Invoke-Command -VMName $Name -Credential $guest -ArgumentList $code -ScriptBlock {
        param($code) & ([scriptblock]::Create($code)) 2>&1 | Out-String -Width 250
    }
}
catch { $output = "ERROR: $($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)" }
Set-Content -Encoding utf8 -LiteralPath $OutFile -Value $output
