function Repair-GpuVMState {
    <#
    .SYNOPSIS
    Rebuilds gpuvm.json for a VM created with GpuVM whose state was lost. The VM must be off.
    If the guest has not booted yet, it also recovers the Sunshine password from its disk.
    .EXAMPLE
    Repair-GpuVMState -Name win10 -Profile max-performance
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Profile = 'balanced',
        [hashtable]$Override
    )
    Assert-Admin
    $vm = Get-VM -Name $Name -ErrorAction Stop
    $existing = try { Get-GpuVMState -Name $Name } catch { $null }
    if ($existing) { Write-Step "La VM '$Name' ya tiene su estado; no hay nada que reparar."; return }
    if ($vm.State -ne 'Off') { throw "Apaga la VM '$Name' antes de repararla." }

    $config = Resolve-GpuVMProfile -Name $Profile -Override $Override
    $vhdPath = (Get-VMHardDiskDrive -VMName $Name | Select-Object -First 1).Path
    $vhd = Get-VHD -Path $vhdPath
    $config['vm']['disk'] = [ordered]@{ sizeGB = [int]($vhd.Size / 1GB); type = [string]$vhd.VhdType }
    $vmDir = Split-Path (Split-Path $vhdPath -Parent) -Parent

    $guest = @(Invoke-WithMountedWindows -Path $vhdPath -ScriptBlock {
            param($root)
            $path = Join-Path $root 'GpuVM\streaming\streaming-config.json'
            if (Test-Path $path) { Read-JsonFile $path }
        }) | Where-Object { $_ -is [System.Collections.IDictionary] } | Select-Object -First 1

    $streaming = $null
    if ($guest) {
        $streaming = [ordered]@{
            provider     = $guest['provider']
            user         = $guest['user']
            password     = ConvertTo-SecureString $guest['password'] -AsPlainText -Force | ConvertFrom-SecureString
            pairedClient = $null
        }
    }
    elseif ($config['streaming'] -and $config['streaming']['provider'] -ne 'none') {
        Write-Warning 'El invitado ya arrancó y borró sus credenciales de Sunshine; connect no podrá emparejar hasta que se restablezcan.'
    }

    $gpu = Get-HostGpu -Match $config['gpu']['match'] | Select-Object -First 1
    $state = [ordered]@{
        name        = $Name
        backend     = $config['backend']
        profile     = $config['name']
        config      = $config
        vmDir       = $vmDir
        vhdPath     = $vhdPath
        gpu         = [ordered]@{
            name          = $gpu.Name
            pnpDeviceId   = $gpu.PnpDeviceId
            driverVersion = $gpu.DriverVersion
            syncedAt      = $null
        }
        edition     = $null
        streaming   = $streaming
        createdAt   = $vm.CreationTime.ToString('o')
        repairedAt  = (Get-Date).ToString('o')
        toolVersion = $script:ToolVersion
        statePath   = Join-Path $vmDir 'gpuvm.json'
    }
    if (-not $PSCmdlet.ShouldProcess($Name, "Reconstruir estado en $($state['statePath'])")) { return }
    Save-GpuVMState $state
    Write-Step "Estado reconstruido. Se asume el driver $($gpu.DriverVersion) del host; si dudas, ejecuta sync-driver."
    Get-GpuVM -Name $Name
}
