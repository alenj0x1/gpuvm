function Get-GpuVMOverview {
    <#
    .SYNOPSIS
    All Hyper-V VMs with their state and live usage (CPU, memory, GPU), whether created with GpuVM or not.
    This is what the app polls every few seconds.
    #>
    [CmdletBinding()]
    param()
    Assert-Admin
    $vms = @(Get-VM)
    # Whether each stopped VM fits in memory now, so the app says so before the click (cheap: one CIM read).
    $freeGB = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
    $anyRunning = [bool]($vms | Where-Object State -eq 'Running')
    # GPU counters and VM processes only if any VM is running: it is the most expensive part of the query.
    $gpuByPid = if ($anyRunning) { Get-GpuUsageByProcess } else { @{} }
    $workers = @{}
    $hostGpus = @{}
    foreach ($p in $(if ($anyRunning) { Get-CimInstance Win32_Process -Filter "Name='vmwp.exe'" })) {
        if ($p.CommandLine -match '([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})') {
            $workers[$Matches[1].ToLowerInvariant()] = [int]$p.ProcessId
        }
    }

    foreach ($vm in $vms) {
        $state = try { Get-GpuVMState -Name $vm.Name } catch { $null }
        $workerPid = $workers[$vm.Id.ToString().ToLowerInvariant()]
        $hasGpu = [bool](Get-VMGpuPartitionAdapter -VMName $vm.Name -ErrorAction SilentlyContinue)
        $address = if ($vm.State -ne 'Running') { $null } else { Get-VMNetworkAdapter -VMName $vm.Name |
            ForEach-Object IPAddresses |
            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' } |
            Select-Object -First 1 }
        $hostGpu = $null
        if ($state) {
            $match = $state['config']['gpu']['match']
            if (-not $hostGpus.ContainsKey($match)) { $hostGpus[$match] = Get-HostGpu -Match $match | Select-Object -First 1 }
            $hostGpu = $hostGpus[$match]
        }
        [ordered]@{
            id             = $vm.Id.ToString()
            name           = $vm.Name
            state          = $vm.State.ToString()
            managed        = [bool]$state
            profile        = if ($state) { $state['profile'] } else { $null }
            edition        = if ($state) { $state['edition'] } else { $null }
            generation     = $vm.Generation
            processorCount = $vm.ProcessorCount
            cpuPercent     = [int]$vm.CPUUsage
            memoryStartupGB = [math]::Round($vm.MemoryStartup / 1GB, 1)
            memoryAssignedGB = [math]::Round($vm.MemoryAssigned / 1GB, 1)
            memoryDemandGB = [math]::Round($vm.MemoryDemand / 1GB, 1)
            uptimeSeconds  = [int]$vm.Uptime.TotalSeconds
            fits           = $vm.State -ne 'Off' -or $freeGB -ge $vm.MemoryStartup / 1GB + 0.3
            fitGB          = Get-FittingMemoryGB -FreeGB $freeGB
            missingGB      = if ($vm.State -eq 'Off') { [math]::Max(0, [math]::Round($vm.MemoryStartup / 1GB + 0.3 - $freeGB, 1)) } else { 0 }
            hasGpu         = $hasGpu
            gpuName        = if ($state) { $state['gpu']['name'] } elseif ($hasGpu) { 'GPU-P' } else { $null }
            gpuPercent     = if ($workerPid -and $gpuByPid.ContainsKey($workerPid)) { [int]$gpuByPid[$workerPid] } else { 0 }
            driverInSync   = if ($state -and $hostGpu) { $hostGpu.DriverVersion -eq $state['gpu']['driverVersion'] } else { $null }
            streaming      = [bool]($state -and $state['streaming'])
            paired         = [bool]($state -and $state['streaming'] -and $state['streaming']['pairedClient'])
            guestCredential = [bool]($state -and $state['guest'])
            address        = $address
            client         = if ($state -and $state['config']['streaming']) { $state['config']['streaming']['client'] } else { $null }
            options        = if ($state) {
                [ordered]@{
                    cpu        = $state['config']['vm']['cpu']['count']
                    memoryGB   = $state['config']['vm']['memoryGB']
                    gpuPercent = $state['config']['gpu']['allocationPercent']
                    diskGB     = $state['config']['vm']['disk']['sizeGB']
                    diskType   = $state['config']['vm']['disk']['type']
                    diskFreeGB = Get-DriveFreeGB $state['config']['vm']['root']
                    captureMode = Get-GpuVMCaptureMode -State $state
                    networkIsolation = Get-GpuVMNetworkIsolation -State $state
                    cleanup    = if ($state['config']['guest'].Contains('cleanup') -and $state['config']['guest']['cleanup']) { $state['config']['guest']['cleanup'] } else { 'none' }
                }
            } else { $null }
        }
    }
}

# GPU usage per process (sum of engines) from the "GPU Engine" counters; a GPU-P VM shows up under its vmwp.exe.
# The whole category is read at once and compared with the previous sample (~10 ms), instead of Get-Counter (~4 s).
function Get-GpuUsageByProcess {
    $usage = @{}
    try {
        if (-not $script:GpuEngineCategory) { $script:GpuEngineCategory = [Diagnostics.PerformanceCounterCategory]::new('GPU Engine') }
        $data = $script:GpuEngineCategory.ReadCategory()['Utilization Percentage']
    }
    catch { return $usage }
    $previous = $script:GpuEnginePrevious
    $current = @{}
    foreach ($instance in $data.Values) {
        $current[$instance.InstanceName] = $instance.Sample
        if (-not $previous -or -not $previous.ContainsKey($instance.InstanceName)) { continue }
        if ($instance.InstanceName -notmatch '^pid_(\d+)_') { continue }
        $id = [int]$Matches[1]
        $value = [Diagnostics.CounterSample]::Calculate($previous[$instance.InstanceName], $instance.Sample)
        $usage[$id] = [math]::Min(100, ($usage[$id] + $value))
    }
    $script:GpuEnginePrevious = $current
    $usage
}