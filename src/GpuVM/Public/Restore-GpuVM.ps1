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
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "Ya existe una VM llamada '$Name'." }
    $root = Get-GpuVMDefaultRoot
    $vmDir = Join-Path $root $Name
    $statePath = Join-Path $vmDir 'gpuvm.json'
    if (-not (Test-Path -LiteralPath $statePath)) { throw "No hay un disco de GpuVM llamado '$Name' en $root." }
    $state = Read-JsonFile $statePath
    $vhdPath = Join-Path $vmDir "Virtual Hard Disks\$Name.vhdx"
    if (-not (Test-Path -LiteralPath $vhdPath)) { throw "Falta el disco $vhdPath." }
    $attached = Get-VM | Get-VMHardDiskDrive | Where-Object { $_.Path -and [IO.Path]::GetFullPath($_.Path) -eq $vhdPath }
    if ($attached) { throw "El disco ya lo usa la VM '$($attached.VMName)'." }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Crear la VM con el disco existente')) { return }

    $config = $state['config']
    Write-Step "Registrando la VM '$Name' con su disco"
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
    Write-Step "VM '$Name' lista. Si el driver de la GPU cambió, se actualiza solo al abrirla."
    Get-GpuVM -Name $Name
}
