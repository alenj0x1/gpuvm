function Get-GpuVM {
    <#
    .SYNOPSIS
    Lists the VMs created with GpuVM and shows whether their GPU driver matches the host's.
    #>
    [CmdletBinding()]
    param([string]$Name = '*')
    Assert-Admin
    foreach ($vm in Get-VM -Name $Name -ErrorAction SilentlyContinue) {
        try { $state = Get-GpuVMState -Name $vm.Name } catch { continue }
        $hostGpu = Get-HostGpu -Match $state['config']['gpu']['match'] | Select-Object -First 1
        $vmDriver = $state['gpu']['driverVersion']
        [pscustomobject]@{
            PSTypeName    = 'GpuVM.Info'
            Name          = $vm.Name
            State         = $vm.State
            Profile       = $state['profile']
            Backend       = $state['backend']
            CPU           = $vm.ProcessorCount
            MemoryGB      = [math]::Round($vm.MemoryStartup / 1GB)
            Gpu           = $state['gpu']['name']
            DriverVersion = $vmDriver
            DriverInSync  = [bool]($hostGpu -and $hostGpu.DriverVersion -eq $vmDriver)
            Edition       = $state['edition']
        }
    }
}
