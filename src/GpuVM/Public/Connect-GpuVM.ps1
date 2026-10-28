function Connect-GpuVM {
    <#
    .SYNOPSIS
    Opens the VM in Moonlight with the image rendered by the GPU. Gets everything ready on its own: updates the driver
    if it changed, powers on, waits for Windows and Sunshine, fixes the session and display, pairs and opens.
    .EXAMPLE
    Connect-GpuVM -Name win11
    Connect-GpuVM -Name win11 -Resolution 2560x1440 -Fps 120 -BitrateKbps 40000
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidatePattern('^\d{3,5}x\d{3,5}$')][string]$Resolution,
        [ValidateRange(10, 480)][int]$Fps,
        [int]$BitrateKbps,
        [ValidateSet('auto', 'H.264', 'HEVC', 'AV1')][string]$Codec,
        [ValidatePattern('^[\w .-]{1,60}$')][string]$App,
        [switch]$Pair
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    if (-not $state['streaming']) { throw "La VM '$Name' se creó sin streaming." }
    $moonlight = Get-MoonlightPath
    if (-not $moonlight) { throw 'Moonlight no está instalado en este equipo. Instálalo con: ./gpuvm.ps1 client-install' }
    Initialize-GpuVMRoot -Path $state['config']['vm']['root']

    $vm = Get-VM -Name $Name
    if ($vm.State -eq 'Off') {
        # While the VM is off is the time to copy the driver if the host's changed (avoids a black screen or code 43).
        $hostGpu = Get-HostGpu -Match $state['config']['gpu']['match'] | Select-Object -First 1
        if ($hostGpu -and $hostGpu.DriverVersion -ne $state['gpu']['driverVersion']) {
            Write-Step 'Actualizando el driver de la GPU'
            Sync-GpuVMDriver -Name $Name -Confirm:$false | Out-Null
            $state = Get-GpuVMState -Name $Name
        }
        Assert-VMCanStart -Name $Name
        Write-Step 'Encendiendo'
        Start-VM -Name $Name
    }
    elseif ($vm.State -eq 'Paused') {
        Resume-VM -Name $Name
    }

    $guest = Get-GpuVMGuestCredential -State $state
    if ($guest) { Wait-GuestReady -Name $Name -Credential $guest }
    if ($guest) { Invoke-GuestPendingWork -Name $Name -Credential $guest }
    if ($guest) {
        try { $null = Set-GuestCaptureMode -Name $Name -Credential $guest -Mode (Get-GpuVMCaptureMode -State $state) }
        catch { Write-Warning "No se pudo ajustar la captura de Sunshine: $($_.Exception.Message)" }
    }

    # The VM's IP is only trusted if it is on the host's network with the VM (see Get-GpuVMEndpoint).
    $endpoint = Get-GpuVMEndpoint -Name $Name
    $address = $endpoint.Address
    $credential = Get-SunshineCredential -State $state
    # Without the guest password GpuVM can't tell whether Windows is still setting itself up; a VM that has been on
    # for a while is past that, so the first-boot message only shows when it can still be the case.
    $firstBoot = -not $guest -and (Get-VM -Name $Name).Uptime.TotalMinutes -lt 15
    $waiting = if ($firstBoot) { 'Esperando a Sunshine (el primer arranque instala Windows y el streaming; puede tardar varios minutos)' } else { 'Esperando a que Sunshine responda' }
    Wait-SunshineReady -Address $address -Credential $credential -Message $waiting
    if ($guest) {
        try {
            if ((Repair-GuestConsoleSession -Name $Name -Credential $guest) -eq 'moved') {
                Write-Step 'Sesión de Windows devuelta a la pantalla de la GPU'
            }
        }
        catch { Write-Warning "No se pudo revisar la sesión dentro de la VM: $($_.Exception.Message)" }
    }
    if ($state['config']['streaming']['virtualDisplay']) {
        Set-SunshineVirtualDisplay -Address $address -Credential $credential -OnlyDisplay:([bool]$state['config']['streaming']['disableHyperVVideo'])
    }

    $override = @{}
    if ($Resolution) { $override['resolution'] = $Resolution }
    if ($Fps) { $override['fps'] = $Fps }
    if ($BitrateKbps) { $override['bitrateKbps'] = $BitrateKbps }
    if ($Codec) { $override['codec'] = $Codec }
    if ($App) { $override['app'] = $App }
    $client = Merge-Hashtable -Base $state['config']['streaming']['client'] -Override $override

    if ($guest -and $state['config']['streaming']['virtualDisplay']) {
        try {
            $result = Set-GuestDisplayResolution -Name $Name -Credential $guest -Resolution $client['resolution'] -Fps $client['fps']
            if ($result.ok) { Write-Step "Pantalla de la VM a $($result.applied)" }
            else {
                $detail = if ($result.PSObject.Properties['available']) { " Disponibles: $($result.available)" } else { '' }
                Write-Warning "No se pudo ajustar la resolución de la VM: $($result.error)$detail"
            }
        }
        catch { Write-Warning "No se pudo ajustar la resolución de la VM: $($_.Exception.Message)" }
    }

    $clientName = $env:COMPUTERNAME
    if ($Pair -or -not (Test-SunshineClientPaired -Address $address -Credential $credential -ClientName $clientName)) {
        Register-MoonlightPairing -Address $address -Credential $credential -MoonlightPath $moonlight -ClientName $clientName -HostAddress $endpoint.HostAddress
        $state = Get-GpuVMState -Name $Name
        $state['streaming']['pairedClient'] = $clientName
        $state['streaming']['pairedAt'] = (Get-Date).ToString('o')
        Save-GpuVMState $state
    }

    if ($state['config']['streaming']['audio'] -eq 'vbcable') {
        if ($guest) {
            try { Set-SunshineAudioSink -Name $Name -GuestCredential $guest -Address $address -Credential $credential }
            catch { Write-Warning "No se pudo revisar el audio dentro de la VM: $($_.Exception.Message)" }
        }
        else {
            $sunshineConfig = try { Invoke-SunshineApi -Address $address -Credential $credential -Path '/api/config' } catch { $null }
            if ($sunshineConfig -and -not $sunshineConfig.PSObject.Properties['virtual_sink']) {
                Write-Warning 'Sunshine todavía no tiene configurado el audio. Guarda la contraseña de Windows de la VM para que GpuVM lo configure.'
            }
        }
    }

    Write-Step "Abriendo a $($client['resolution']) y $($client['fps']) FPS"
    # Moonlight runs as the signed-in user, not as administrator: it talks to a server the guest controls.
    Start-UnelevatedProcess -FilePath $moonlight -ArgumentList (Get-MoonlightStreamArguments -Address $address -Client $client) | Out-Null
}
