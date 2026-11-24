# Machines run by the Host Compute Service: needs only Windows' "Virtual Machine Platform", so it works on Windows
# Home. The engine is in GpuVM's service (gpuvm-host hcs ...); the guest is reached through GpuVM's agent.

function Get-HcsGpuChoice {
    param([System.Collections.IDictionary]$Config)
    $match = [string]$Config['gpu']['match']
    if ($match -match 'nvidia|geforce|rtx|gtx|quadro') { return 'nvidia' }
    if ($match -match 'intel|arc|uhd|iris') { return 'intel' }
    if ($match -match 'amd|radeon') { return 'amd' }
    'default'
}

function Get-HcsChecks {
    param([System.Collections.IDictionary]$Config)
    $checks = [System.Collections.Generic.List[object]]::new()
    $vmp = Get-VirtualMachinePlatformState
    if ($vmp -eq 'Disabled') {
        $checks.Add((New-CheckResult 'Virtual Machine Platform' Fail 'Windows'' "Virtual Machine Platform" is off: GpuVM can turn it on (needs a restart).'))
        return $checks
    }
    $checks.Add((New-CheckResult 'Virtual Machine Platform' Ok 'On'))
    if (-not (Get-Service vmcompute -ErrorAction SilentlyContinue)) {
        $checks.Add((New-CheckResult 'Host Compute Service' Fail 'The Host Compute Service (vmcompute) is missing; restart after turning on Virtual Machine Platform.'))
        return $checks
    }
    try {
        $gpus = @((Invoke-GpuVMHcs @('gpus'))['gpus'])
        $want = Get-HcsGpuChoice -Config $Config
        $vendor = @{ nvidia = 'VEN_10DE'; intel = 'VEN_8086'; amd = 'VEN_1002' }[$want]
        if (-not $gpus) { $checks.Add((New-CheckResult 'GPU' Warn 'No GPU this PC can share was found; machines run without one.')) }
        elseif ($vendor -and -not ($gpus | Where-Object { $_ -match $vendor })) { $checks.Add((New-CheckResult 'GPU' Warn "No shareable $want GPU; Windows picks one.")) }
        else { $checks.Add((New-CheckResult 'GPU' Ok "$($gpus.Count) GPU(s) can be shared")) }
    }
    catch { $checks.Add((New-CheckResult 'GPU' Warn "GPUs couldn't be listed: $($_.Exception.Message)")) }
    $checks
}

function New-HcsMachineFromDisk {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][System.Collections.IDictionary]$Config, [Parameter(Mandatory)][string]$Source, [switch]$Own)
    $root = Get-GpuVMHcsRoot
    $memory = [string]([int64]$Config['vm']['memoryGB'] * 1024)
    $cpus = [string]$Config['vm']['cpu']['count']
    $arguments = @('create', $root, $Name, $Source, $memory, $cpus, '--gpu', (Get-HcsGpuChoice -Config $Config))
    if ($Own) { $arguments += '--own-disk' }
    $null = Invoke-GpuVMHcs $arguments
    Clear-GpuVMHcsCache
    Join-Path $root $Name
}

function Install-HcsAgent {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Root)
    $package = Get-AgentPackage
    Write-Step 'Installing GpuVM''s agent (how GpuVM reaches Windows in the machine)'
    $r = Invoke-GpuVMHcs @('install-agent', $Root, $Name, $package.Exe)
    [ordered]@{ vmId = $r['vmId']; version = $package.Version; installedAt = (Get-Date).ToString('o'); offline = $true }
}

Register-GpuVMBackend -Name 'hcs' -Description 'Host Compute Service with GPU-PV; works on every Windows edition (no Hyper-V needed).' -Operations @{
    Test       = { param($Config) Get-HcsChecks -Config $Config }

    New        = {
        param($Context)
        $name = $Context.Name
        $config = $Context.Config
        $root = Get-GpuVMHcsRoot
        if (Test-Path -LiteralPath (Join-Path $root $name)) { throw "The folder $(Join-Path $root $name) already exists from an earlier attempt. Choose another name or delete it." }
        Initialize-GpuVMRoot -Path $root
        $gpu = Get-HostGpu -Match $config['gpu']['match'] | Select-Object -First 1
        if (-not $gpu) { throw "The GPU '$($config['gpu']['match'])' wasn't found on the host." }
        Write-Step "Reading the files of driver $($gpu.DriverVersion) for $($gpu.Name)"
        $fileSet = Get-GpuDriverFileSet -PnpDeviceId $gpu.PnpDeviceId -DriverVersion $gpu.DriverVersion
        $staging = Join-Path $root ".staging-$name.vhdx"
        try {
            New-WindowsVhdx -Path $staging -SizeGB $config['vm']['disk']['sizeGB'] -Type Dynamic -ImageFile $Context.ImageFile -ImageIndex $Context.ImageIndex `
                -Edition $Context.Edition -Language $Context.Language -Customize { param($winRoot) Initialize-NewGuestWindows -Root $winRoot -Context $Context -FileSet $fileSet }
            $dir = New-HcsMachineFromDisk -Name $name -Config $config -Source $staging -Own
            $agent = Install-HcsAgent -Name $name -Root $root
        }
        catch {
            Write-Step 'Creation failed; cleaning up what was already made'
            if (Test-Path -LiteralPath (Join-Path (Join-Path $root $name) 'hcs-machine.json')) { try { $null = Invoke-GpuVMHcs @('delete', $root, $name) } catch { } }
            Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
            throw
        }
        [ordered]@{
            name = $name; backend = 'hcs'; profile = $config['name']; config = $config; vmDir = $dir; vhdPath = Join-Path $dir 'disk.vhdx'
            gpu = [ordered]@{ name = $gpu.Name; pnpDeviceId = $gpu.PnpDeviceId; driverVersion = $gpu.DriverVersion; syncedAt = (Get-Date).ToString('o') }
            agentChannel = $agent; createdAt = (Get-Date).ToString('o'); toolVersion = $script:ToolVersion; statePath = Join-Path $dir 'gpuvm.json'
        }
    }

    Clone      = {
        param($Context)
        $name = $Context.Name
        $config = $Context.Config
        $template = $Context.Template
        $root = Get-GpuVMHcsRoot
        if (Test-Path -LiteralPath (Join-Path $root $name)) { throw "The folder $(Join-Path $root $name) already exists from an earlier attempt. Choose another name or delete it." }
        Initialize-GpuVMRoot -Path $root
        Write-Step "Creating the disk on top of the template '$($template['name'])'"
        $dir = New-HcsMachineFromDisk -Name $name -Config $config -Source $template['vhdPath']
        try {
            Invoke-WithMountedWindows -Path (Join-Path $dir 'disk.vhdx') -ScriptBlock {
                param($winRoot)
                Write-Step 'Giving the copy its own streaming identity'
                Reset-ClonedGuestIdentity -WindowsRoot $winRoot
            }
            $agent = Install-HcsAgent -Name $name -Root $root
        }
        catch {
            Write-Step 'Creation failed; cleaning up what was already made'
            try { $null = Invoke-GpuVMHcs @('delete', $root, $name) } catch { }
            throw
        }
        [ordered]@{
            name = $name; backend = 'hcs'; profile = $config['name']; config = $config; vmDir = $dir; vhdPath = Join-Path $dir 'disk.vhdx'
            gpu = $template['gpu']; template = $template['name']; agentChannel = $agent
            createdAt = (Get-Date).ToString('o'); toolVersion = $script:ToolVersion; statePath = Join-Path $dir 'gpuvm.json'
        }
    }

    Apply      = {
        param($Name, $Config)
        $root = Get-GpuVMHcsRoot
        $null = Invoke-GpuVMHcs @('set', $root, $Name, '--memory-mb', [string]([int64]$Config['vm']['memoryGB'] * 1024), '--cpus', [string]$Config['vm']['cpu']['count'], '--gpu', (Get-HcsGpuChoice -Config $Config))
        Clear-GpuVMHcsCache
    }

    SyncDriver = { param($Name, $State) Sync-HyperVGpuPDriver -Name $Name -State $State }

    Rename     = { param($Name, $NewName, $State) throw 'Renaming isn''t available yet for machines that run without Hyper-V.' }

    Remove     = {
        param($Name, $State, $DeleteDisk)
        $root = Get-GpuVMHcsRoot
        if (-not (Test-GpuVMHcsMachine -Name $Name)) { return }
        try { $null = Invoke-GpuVMHcs @('off', $root, $Name) } catch { }
        if ($DeleteDisk) { $null = Invoke-GpuVMHcs @('delete', $root, $Name) }
        else {
            # Keep the disk and GpuVM's state, forget the machine: its record goes and its agent is unregistered.
            $record = Join-Path (Join-Path $root $Name) 'hcs-machine.json'
            $vmId = try { (Get-Content -Raw -LiteralPath $record | ConvertFrom-Json).vmId } catch { $null }
            Remove-Item -LiteralPath $record -Force
            if ($vmId) { try { Remove-GpuVMAgentRegistration -VMId $vmId } catch { } }
        }
        Clear-GpuVMHcsCache
    }
}
