function Restore-GpuVM {
    <#
    .SYNOPSIS
    Creates a VM again from a disk that was kept when its VM was removed. Windows, its apps and games stay as
    they were; the VM gets the same name, settings, Sunshine pairing and saved password.
    .EXAMPLE
    Restore-GpuVM -Name win10
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name)
    Assert-Admin
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "There's already a VM called '$Name'." }
    $root = Get-GpuVMDefaultRoot
    $vmDir = Join-Path $root $Name
    $statePath = Join-Path $vmDir 'gpuvm.json'
    if (-not (Test-Path -LiteralPath $statePath)) { throw "There's no GpuVM disk called '$Name' in $root." }
    $state = Read-JsonFile $statePath
    $vhdPath = Join-Path $vmDir "Virtual Hard Disks\$Name.vhdx"
    if (-not (Test-Path -LiteralPath $vhdPath)) { throw "The disk $vhdPath is missing." }
    $attached = Get-VM | Get-VMHardDiskDrive | Where-Object { $_.Path -and [IO.Path]::GetFullPath($_.Path) -eq $vhdPath }
    if ($attached) { throw "The VM '$($attached.VMName)' already uses the disk." }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Create the VM with the existing disk')) { return }

    $config = $state['config']
    Write-Step "Registering the VM '$Name' with its disk"
    New-VM -Name $Name -Generation 2 -MemoryStartupBytes ([int64]$config['vm']['memoryGB'] * 1GB) -VHDPath $vhdPath -Path $root | Out-Null
    try { Invoke-GpuVMBackend -Backend $state['backend'] -Operation Apply -Arguments $Name, $config }
    catch { Remove-VM -Name $Name -Force -ErrorAction SilentlyContinue; throw }

    # The paths now come from where the disk really is, not from what the file said.
    $state['name'] = $Name
    $state['vmDir'] = $vmDir
    $state['vhdPath'] = $vhdPath
    $state['statePath'] = $statePath
    $state['restoredAt'] = (Get-Date).ToString('o')
    Save-GpuVMState $state
    Write-Step "VM '$Name' is ready. If the GPU driver changed, it updates on its own when you open it."
    Get-GpuVM -Name $Name
}
