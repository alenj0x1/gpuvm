function Get-GpuVMHostInfo {
    <#
    .SYNOPSIS
    Machine limits for the UI: host threads, memory and GPU.
    #>
    [CmdletBinding()]
    param([string]$GpuMatch = 'NVIDIA')
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cs = Get-CimInstance Win32_ComputerSystem
    $gpu = Get-HostGpu -Match $GpuMatch | Select-Object -First 1
    [ordered]@{
        logicalProcessors = [int]$cpu.NumberOfLogicalProcessors
        memoryGB          = [int][math]::Floor($cs.TotalPhysicalMemory / 1GB)
        gpuName           = if ($gpu) { $gpu.Name } else { $null }
    }
}
