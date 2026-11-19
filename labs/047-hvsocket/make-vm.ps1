# Creates (or deletes with -Remove) the disposable test VM used by labs 047-050: Windows 10 Pro from the ISO,
# 2 GB static memory, 4 threads, GPU-P + Sunshine like any GpuVM machine. The guest password is random and kept only
# in the VM's GpuVM state (DPAPI) and in labs/047-hvsocket/out/guest.xml (Export-Clixml, DPAPI, git-ignored).
# Takes/release the shared lab lock around the heavy part. Run elevated.
param(
    [string]$Name = 'agentlab',
    [string]$IsoPath = 'C:\Users\you\Downloads\Win10_22H2_Spanish_Mexico_x64v1.iso',
    [int]$MemoryGB = 2,
    [switch]$Remove,
    [string]$Me = 'agents-phase0'
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null
& (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What "lab 047: $(if ($Remove) { 'delete' } else { 'create' }) test VM $Name" -Me $Me
if ($LASTEXITCODE -ne 0) { throw 'no lock' }
try {
    if ($Remove) {
        Remove-GpuVM -Name $Name -Confirm:$false
        Remove-Item (Join-Path $out 'guest.xml') -ErrorAction SilentlyContinue
        return
    }
    $bytes = [byte[]]::new(18); [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $pw = 'Lb7!' + [Convert]::ToBase64String($bytes).Replace('/', 'x').Replace('+', 'y')
    $cred = [pscredential]::new('gpuvm', (ConvertTo-SecureString $pw -AsPlainText -Force))
    $cred | Export-Clixml (Join-Path $out 'guest.xml')
    # GpuVM requires 4 GB per machine (Windows 11); this Windows 10 test VM runs on $MemoryGB GB, set in Hyper-V
    # only (lab VM, deleted at the end), because the host has ~2.5 GB free next to win-gpu.
    $t = Measure-Command {
        New-GpuVM -Name $Name -IsoPath $IsoPath -Credential $cred -Override @{ vm = @{ memoryGB = 4; cpu = @{ count = 4 }; disk = @{ sizeGB = 64 } } } -Confirm:$false
        Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes ([int64]$MemoryGB * 1GB)
        Start-VM -Name $Name
    }
    "created and started in {0:N0} s" -f $t.TotalSeconds
}
finally {
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    "lock released $(Get-Date -Format HH:mm:ss)"
}
