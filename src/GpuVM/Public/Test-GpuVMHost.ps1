function Test-GpuVMHost {
    <#
    .SYNOPSIS
    Checks whether the machine is ready to create a GPU VM using the given profile.
    .EXAMPLE
    Test-GpuVMHost -Profile max-performance
    #>
    [CmdletBinding()]
    param(
        [string]$Profile = 'balanced',
        [hashtable]$Override
    )
    $checks = [System.Collections.Generic.List[object]]::new()

    $os = Get-CimInstance Win32_OperatingSystem
    $isClientPro = $os.Caption -match 'Pro|Enterprise|Education|Server'
    $checks.Add((New-CheckResult 'Windows' ($isClientPro ? 'Ok' : 'Fail') "$($os.Caption) (build $($os.BuildNumber))"))
    $checks.Add((New-CheckResult 'Administrador' ((Test-IsAdmin) ? 'Ok' : 'Warn') ((Test-IsAdmin) ? '' : 'Crear y modificar VMs requiere PowerShell como administrador.')))

    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $virt = $cs.HypervisorPresent -or $cpu.VirtualizationFirmwareEnabled
    $checks.Add((New-CheckResult 'Virtualización' ($virt ? 'Ok' : 'Fail') ($virt ? 'Hipervisor activo o VT-x habilitado' : 'Activa Intel VT-x / AMD-V en la BIOS.')))

    $hostMemoryGB = $cs.TotalPhysicalMemory / 1GB
    $logical = [int]$cpu.NumberOfLogicalProcessors

    try {
        $config = Resolve-GpuVMProfile -Name $Profile -Override $Override
        $problems = Test-GpuVMProfileData -Config $config -HostLogicalProcessors $logical -HostMemoryGB $hostMemoryGB
        if ($problems.Count) { $checks.Add((New-CheckResult "Perfil $Profile" Fail ($problems -join ' '))) }
        else {
            $c = $config['vm']
            $checks.Add((New-CheckResult "Perfil $Profile" Ok "$($c['cpu']['count'])/$logical hilos, $($c['memoryGB'])/$([math]::Round($hostMemoryGB)) GB, disco $($c['disk']['type']) de $($c['disk']['sizeGB']) GB"))
        }
    }
    catch {
        $checks.Add((New-CheckResult "Perfil $Profile" Fail $_.Exception.Message))
        return $checks
    }

    # Hyper-V fixed memory must be free when the VM powers on, not just installed.
    $freeGB = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)
    $memGB = $config['vm']['memoryGB']
    $memStatus = if ($freeGB -ge $memGB + 0.5) { 'Ok' } else { 'Warn' }
    $memDetail = "$freeGB GB libres ahora; la VM necesita $memGB GB fijos para encender"
    if ($memStatus -eq 'Warn') { $memDetail += '. Cierra programas o usa -Override @{vm=@{memoryGB=6}}' }
    $checks.Add((New-CheckResult 'Memoria libre' $memStatus $memDetail))

    $gpu = Get-HostGpu -Match $config['gpu']['match'] | Select-Object -First 1
    if ($gpu) { $checks.Add((New-CheckResult 'GPU' Ok "$($gpu.Name), driver $($gpu.DriverVersion)")) }
    else { $checks.Add((New-CheckResult 'GPU' Fail "No hay una GPU que coincida con '$($config['gpu']['match'])'.")) }

    $root = $config['vm']['root']
    $drive = Get-Volume -DriveLetter $root.Substring(0, 1) -ErrorAction SilentlyContinue
    if ($drive) {
        $freeGB = [math]::Round($drive.SizeRemaining / 1GB)
        $needGB = if ($config['vm']['disk']['type'] -eq 'Fixed') { $config['vm']['disk']['sizeGB'] + 10 } else { 40 }
        $status = if ($freeGB -ge $needGB) { 'Ok' } else { 'Fail' }
        $checks.Add((New-CheckResult 'Espacio' $status "$freeGB GB libres en $($root.Substring(0, 2)); se necesitan ~$needGB GB"))
    }
    else {
        $checks.Add((New-CheckResult 'Espacio' Fail "No existe la unidad de $root"))
    }

    if ($config['streaming'] -and $config['streaming']['provider'] -ne 'none') {
        $moonlight = Get-MoonlightPath
        $checks.Add((New-CheckResult 'Moonlight' ($moonlight ? 'Ok' : 'Warn') ($moonlight ? $moonlight : 'No está instalado; hace falta para ver la VM. Instálalo con: ./gpuvm.ps1 client-install')))
        $manifest = Get-ComponentManifest
        $components = (Get-StreamingComponentNames $config['streaming'] | ForEach-Object { "$_ $($manifest[$_]['version'])" }) -join ', '
        $checks.Add((New-CheckResult 'Streaming' Ok "$components (se descargan y verifican al crear la VM)"))
    }

    foreach ($check in (Invoke-GpuVMBackend -Backend $config['backend'] -Operation Test -Arguments (, $config))) { $checks.Add($check) }
    $checks
}
