function Get-GpuVMHome {
    <#
    .SYNOPSIS
    What the home screen shows: the last machine opened, which machines fit in memory right now (and what is using
    it when one doesn't), and what needs attention across all of them, each with the action that fixes it.
    #>
    [CmdletBinding()]
    param()
    Assert-Admin
    $os = Get-CimInstance Win32_OperatingSystem
    $freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $root = Get-GpuVMDefaultRoot
    $diskFreeGB = Get-DriveFreeGB $root

    $hostGpus = @{}
    $machines = [System.Collections.Generic.List[object]]::new()
    $attention = [System.Collections.Generic.List[object]]::new()
    $last = $null
    foreach ($vm in Get-VM) {
        $state = try { Get-GpuVMState -Name $vm.Name } catch { $null }
        $needGB = [math]::Round($vm.MemoryStartup / 1GB + 0.3, 1)
        $machines.Add([ordered]@{
                name     = $vm.Name
                state    = $vm.State.ToString()
                memoryGB = [math]::Round($vm.MemoryStartup / 1GB, 1)
                needGB   = $needGB
                fits     = $vm.State -ne 'Off' -or $freeGB -ge $needGB
                fitGB    = Get-FittingMemoryGB -FreeGB $freeGB
            })
        if (-not $state) { continue }
        if ($state.Contains('lastOpenedAt') -and $state['lastOpenedAt'] -and (-not $last -or [datetime]$state['lastOpenedAt'] -gt [datetime]$last['at'])) {
            $last = [ordered]@{ name = $vm.Name; at = $state['lastOpenedAt'] }
        }

        $issue = { param($kind, $text, $label, $cmd, $arguments)
            $attention.Add([ordered]@{ vm = $vm.Name; kind = $kind; text = $text; label = $label; cmd = $cmd; args = $arguments }) }
        $match = $state['config']['gpu']['match']
        if (-not $hostGpus.ContainsKey($match)) { $hostGpus[$match] = Get-HostGpu -Match $match | Select-Object -First 1 }
        $hostGpu = $hostGpus[$match]
        if ($hostGpu -and $state['gpu'] -and $hostGpu.DriverVersion -ne $state['gpu']['driverVersion']) {
            & $issue 'driver' "Its GPU driver isn't the one on this PC ($($hostGpu.DriverVersion))" 'Update driver' 'Sync-GpuVMDriver' @{ Name = $vm.Name; Confirm = $false; ShutdownIfRunning = $true }
        }
        if (-not $state['guest']) {
            & $issue 'password' 'Its Windows password is missing, so things inside it can''t be fixed' 'Save password' $null $null
        }
        elseif ($state['streaming'] -and -not $state['streaming']['pairedClient'] -and
            -not ($state.Contains('use') -and $state['use'] -eq 'agent') -and -not (Test-GpuVMDisposable -State $state)) {
            & $issue 'pairing' 'The viewer isn''t paired with it yet' 'Pair' 'Connect-GpuVM' @{ Name = $vm.Name; Pair = $true }
        }
        $pending = @(if ($state.Contains('pendingApps')) { $state['pendingApps'] | Where-Object { $_ } })
        if ($pending.Count) {
            $names = @($pending | ForEach-Object { $entry = (Get-AppCatalog)[$_]; if ($entry) { $entry['name'] } else { $_ } })
            & $issue 'apps' "Still to install: $($names -join ', ')" $(if ($vm.State -eq 'Off') { 'Start and install' } else { 'Install' }) 'Install-GpuVMApp' @{ Name = $vm.Name; App = $pending }
        }
    }
    if ($diskFreeGB -lt 40) {
        $attention.Add([ordered]@{ vm = $null; kind = 'disk'; text = "$diskFreeGB GB left on the machines' disk"; label = 'See disks'; cmd = $null; args = $null })
    }

    $skip = 'vmmem', 'vmwp', 'Memory Compression', 'System', 'Registry', 'Idle', 'MsMpEng', 'dwm', 'csrss', 'svchost', 'lsass', 'explorer'
    $top = @(Get-Process | Where-Object { $_.ProcessName -notin $skip } | Group-Object ProcessName |
            ForEach-Object { [ordered]@{ name = $_.Name; gb = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1GB, 1) } } |
            Sort-Object { $_['gb'] } -Descending | Select-Object -First 3 | Where-Object { $_['gb'] -ge 0.3 })

    [ordered]@{
        lastOpened = $last
        host       = [ordered]@{ memoryTotalGB = $totalGB; memoryFreeGB = $freeGB; diskFreeGB = $diskFreeGB; topProcesses = $top }
        machines   = $machines
        attention  = $attention
    }
}
