# Lab 058: puts a locally built gpuvm-agent.exe (guest/agent/dist) into ONE disposable lab machine, over PowerShell
# Direct, to measure a new guest agent before it ships. Only the exe changes (service stopped, exe replaced, service
# started; its helper restarts with it); the installed GpuVM and its templates are not touched. Run elevated.
#   .\swap-agent.ps1 -Name c058-1234
param([Parameter(Mandatory)][string]$Name)
$ErrorActionPreference = 'Stop'
if ($Name -notlike 'c058-*') { throw "only lab 058's own machines (c058-*): $Name" }
$exe = Join-Path $PSScriptRoot '..\..\guest\agent\dist\gpuvm-agent.exe'
if (-not (Test-Path $exe)) { throw "build it first: guest\agent\build.ps1" }
Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
$credential = & (Get-Module GpuVM) { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $Name
if (-not $credential) { throw "no saved account for $Name" }
$s = New-PSSession -VMName $Name -Credential $credential
try {
    $staging = 'C:\ProgramData\GpuVM\Agent\staging-058'
    Invoke-Command -Session $s { param($d) New-Item -ItemType Directory -Force $d | Out-Null } -ArgumentList $staging
    Copy-Item $exe -Destination "$staging\gpuvm-agent.exe" -ToSession $s -Force
    Invoke-Command -Session $s {
        param($d)
        $target = 'C:\Program Files\GpuVM Agent\gpuvm-agent.exe'
        $before = (& $target version | Out-String).Trim()
        Stop-Service GpuVMAgent -Force
        $t = Get-Date
        while ((Get-Process gpuvm-agent -ErrorAction SilentlyContinue) -and ((Get-Date) - $t).TotalSeconds -lt 15) { Start-Sleep -Milliseconds 200 }
        Copy-Item "$d\gpuvm-agent.exe" $target -Force
        Remove-Item $d -Recurse -Force
        Start-Service GpuVMAgent
        [pscustomobject]@{ before = $before; after = (& $target version | Out-String).Trim(); service = (Get-Service GpuVMAgent).Status.ToString() }
    } -ArgumentList $staging | Select-Object before, after, service | Format-List | Out-String
}
finally { Remove-PSSession $s }
