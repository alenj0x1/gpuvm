# Registers (or with -Remove unregisters) Hyper-V's loopback GUID as a fake "machine" for the broker, so the stub can
# run on the host itself (STUB052_TARGET=loopback) without a VM: same handshake, frames and limits, no VMBus.
# The raw secret for the stub goes to C:\GpuVM\lab052\loopback\secret.raw (administrators only). Run elevated.
param([switch]$Remove)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
$id = 'e0e16197-dd56-4a10-9195-5ee7a155a838'
$lab = 'C:\GpuVM\lab052\loopback'
$agents = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'GpuVM\agents'
$reg = Join-Path $agents $id
if ($Remove) {
    if (Test-Path $reg) { Remove-Item $reg -Recurse -Force }
    if (Test-Path $lab) { Remove-Item $lab -Recurse -Force }
    'loopback registration removed'
    return
}
& (Get-Module GpuVM) {
    param($agents, $reg, $lab, $id)
    Initialize-AgentFolder -Path $agents
    Initialize-AgentFolder -Path $reg
    New-Item -ItemType Directory -Force $lab | Out-Null
    $k = [byte[]]::new(32); [Security.Cryptography.RandomNumberGenerator]::Fill($k)
    Write-AgentSecret -Folder $reg -Secret $k
    [IO.File]::WriteAllBytes((Join-Path $lab 'secret.raw'), $k)
    Write-JsonFile -Path (Join-Path $reg 'agent.json') -Data ([ordered]@{ vmId = $id; name = 'loopback052'; folder = $lab; version = 'stub-052' })
} $agents $reg $lab $id
"loopback registered as 'loopback052' (log: $lab\agent.log)"
