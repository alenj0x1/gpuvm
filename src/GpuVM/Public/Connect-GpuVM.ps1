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
        [switch]$Pair,
        # The monitor to open on: a monitor's id (Get-GpuVMMonitor) or "primary". Without it, the one saved for the VM.
        [ValidateLength(0, 300)][string]$Monitor,
        # Opens with this much memory when it doesn't fit as configured (saved, like changing it in Options).
        [ValidateRange(4, 256)][int]$MemoryGB,
        # GpuVM's viewer: gets the machine ready and returns the stream arguments ({ viewerLaunch }) for the app to
        # open the viewer itself, instead of opening Moonlight.
        [switch]$Viewer
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    if (-not $state['streaming']) { throw "The VM '$Name' was created without streaming." }
    if ($Viewer) {
        $moonlight = Get-GpuVMViewerPath
        if (-not $moonlight) { throw 'GpuVM''s viewer isn''t installed. Install GpuVM again.' }
    }
    else {
        $moonlight = Get-MoonlightPath
        if (-not $moonlight) { throw 'Moonlight isn''t installed on this PC. Install it with: ./gpuvm.ps1 client-install' }
    }
    Initialize-GpuVMRoot -Path $state['config']['vm']['root']

    $vm = Get-VM -Name $Name
    if ($vm.State -eq 'Off') {
        # While the VM is off is the time to copy the driver if the host's changed (avoids a black screen or code 43).
        $hostGpu = Get-HostGpu -Match $state['config']['gpu']['match'] | Select-Object -First 1
        if ($hostGpu -and $hostGpu.DriverVersion -ne $state['gpu']['driverVersion']) {
            Write-Step 'Updating the GPU driver'
            Sync-GpuVMDriver -Name $Name -Confirm:$false | Out-Null
            $state = Get-GpuVMState -Name $Name
        }
        if ($MemoryGB -and $MemoryGB -ne $state['config']['vm']['memoryGB']) {
            Write-Step "Memory: $MemoryGB GB"
            Set-GpuVM -Name $Name -Override @{ vm = @{ memoryGB = $MemoryGB } } -Confirm:$false | Out-Null
            $state = Get-GpuVMState -Name $Name
        }
        Assert-VMCanStart -Name $Name
        Write-Step 'Starting'
        Start-VM -Name $Name
    }
    else {
        # Started from somewhere else (Hyper-V Manager) or before this version: it gets isolated now too.
        Update-GpuVMNetworkIsolation -Name $Name -State $state
        if ($vm.State -eq 'Paused') { Resume-VM -Name $Name }
        # Already open in Moonlight (a second click, or opened by hand): brought to the front instead of opening another.
        if (-not $Pair) {
            $open = try { Find-MoonlightStream -Address (Get-GpuVMEndpoint -Name $Name).Address } catch { $null }
            if ($open) {
                Write-Step 'It''s already open'
                Show-ProcessWindow -Id $open
                return
            }
        }
    }

    $guest = Get-GpuVMGuestCredential -State $state
    if ($guest) {
        # Updates found when GpuVM shut the VM down finish installing while Windows starts.
        $bootMessage = if ($state.Contains('updatesPending') -and $state['updatesPending']) { 'Finishing updates' } else { 'Waiting for Windows' }
        Wait-GuestReady -Name $Name -Credential $guest -BootMessage $bootMessage
        Open-GuestSession -Name $Name -Credential $guest
        $null = Wait-GuestSignIn -Name $Name -Credential $guest
        # An imported machine still has the streaming identity it was exported with: it gets its own, inside the VM,
        # before Sunshine is used for anything (Import-GpuVM never mounts the file's disk on this PC).
        if ($state.Contains('pendingIdentityReset') -and $state['pendingIdentityReset']) {
            Write-Step 'Giving the machine its own streaming identity'
            Reset-GuestStreamingIdentity -Name $Name -Credential $guest -WebCredential (Get-SunshineCredential -State $state)
            $state = Get-GpuVMState -Name $Name
            $state['pendingIdentityReset'] = $false
            Save-GpuVMState $state
            Write-Step 'Restarting Windows to finish'
            # -Wait -For Heartbeat: the next checks must see the restarted Windows, not the one still shutting down.
            Restart-VM -Name $Name -Type Reboot -Force -Wait -For Heartbeat -Timeout 600
            Wait-GuestReady -Name $Name -Credential $guest -BootMessage 'Waiting for Windows'
            Open-GuestSession -Name $Name -Credential $guest
            $null = Wait-GuestSignIn -Name $Name -Credential $guest
        }
        if ($state.Contains('updatesPending') -and $state['updatesPending']) {
            $state = Get-GpuVMState -Name $Name
            $state['updatesPending'] = $false
            Save-GpuVMState $state
        }
        # An agent removal that couldn't finish (the machine was off, or `agent` was still signed in) finishes now.
        if ($state.Contains('agentRemovalPending') -and $state['agentRemovalPending']) {
            if (Complete-GuestAgentRemoval -Name $Name -Credential $guest) {
                $state = Get-GpuVMState -Name $Name
                $state.Remove('agentRemovalPending')
                Save-GpuVMState $state
            }
        }
        # An agent machine whose agent is pending or older than this build's gets it now (copies of older templates).
        if (Update-GpuVMAgentIfStale -Name $Name -Credential $guest) {
            Wait-GuestReady -Name $Name -Credential $guest -BootMessage 'Waiting for Windows'
            Open-GuestSession -Name $Name -Credential $guest
            $null = Wait-GuestSignIn -Name $Name -Credential $guest
        }
        $state = Get-GpuVMState -Name $Name
    }
    $audioCheck = $null
    $audioLater = $false
    try {
        # Work that lasts until the guest restarts is done once per boot (lab 019: repeating it was most of a 25 s open).
        $boot = if ($guest) { try { Get-GuestBootTime -Name $Name -Credential $guest } catch { '' } } else { '' }
        $done = if ($boot -and $state.Contains('guestPrepared') -and $state['guestPrepared'] -and [string]$state['guestPrepared']['boot'] -eq $boot) { $state['guestPrepared'] } else { @{} }
        $prepared = @{ boot = $boot }
        # First open since boot: the speaker is checked in the background while the rest is prepared.
        if ($guest -and -not $done.Count -and (Test-GpuVMAudio $state['config']['streaming'])) {
            $audioCheck = Start-GuestAudioCheck -Name $Name -Credential $guest
        }

        # Display first: a display change after Sunshine tested its encoders makes it test them all again when Moonlight
        # connects (10-15 s of black screen, lab 008). When the mode does change here, Sunshine is restarted right away
        # and tests them while the rest of the work runs.
        $override = @{}
        if ($Resolution) { $override['resolution'] = $Resolution }
        if ($Fps) { $override['fps'] = $Fps }
        if ($BitrateKbps) { $override['bitrateKbps'] = $BitrateKbps }
        if ($Codec) { $override['codec'] = $Codec }
        if ($App) { $override['app'] = $App }
        $client = Merge-Hashtable -Base $state['config']['streaming']['client'] -Override $override
        # Moonlight goes on this monitor, and "the monitor's rate" (fps 0) is this one's.
        $chosenMonitor = if ($Monitor) { $Monitor } elseif ($client.Contains('monitor')) { [string]$client['monitor'] } else { '' }
        $target = try { Resolve-HostMonitor -Monitor $chosenMonitor } catch { $null }
        if ([int]$client['fps'] -le 0) { $client['fps'] = Resolve-GpuVMStreamFps 0 -Hz $(if ($target) { $target['hz'] } else { 0 }) }
        $restartSunshine = $false
        if ($guest) {
            # The display is set in the user's session, so it has to be on the screen Sunshine captures first.
            try {
                if ((Repair-GuestConsoleSession -Name $Name -Credential $guest) -eq 'moved') {
                    Write-Step 'Windows session moved back to the GPU''s display'
                }
            }
            catch { Write-Warning "Couldn't check the session inside the VM: $($_.Exception.Message)" }
        }
        if ($guest -and $state['config']['streaming']['virtualDisplay']) {
            # The monitor's rate (fps 0) is resolved now: opening on another monitor sets the display again.
            $mode = "$($client['resolution'])@$(Resolve-GpuVMStreamFps $client['fps'])"
            if ($done['display'] -eq $mode) { $prepared['display'] = $mode }
            else {
                try {
                    $result = Set-GuestDisplayResolution -Name $Name -Credential $guest -Resolution $client['resolution'] -Fps $client['fps']
                    if ($result.ok) {
                        Write-Step "The VM's display set to $($result.applied)"
                        $prepared['display'] = $mode
                        $restartSunshine = $result.changed
                    }
                    else {
                        $detail = if ($result.PSObject.Properties['available']) { " Available: $($result.available)" } else { '' }
                        Write-Warning "Couldn't set the VM's resolution: $($result.error)$detail"
                    }
                }
                catch { Write-Warning "Couldn't set the VM's resolution: $($_.Exception.Message)" }
            }
        }
        # Gamepads (ViGEmBus): installed once; Sunshine only sees the driver after a restart.
        # Remembered per VM, not per boot: checking for the driver right after boot took ~6 s.
        if ($guest -and -not ($state.Contains('gamepad') -and $state['gamepad'])) {
            try {
                if (Install-GuestGamepad -Name $Name -Credential $guest) { $restartSunshine = $true }
                $state = Get-GpuVMState -Name $Name
                $state['gamepad'] = 'vigembus'
                Save-GpuVMState $state
            }
            catch { Write-Warning "Couldn't set up controller support in the VM: $($_.Exception.Message)" }
        }
        $captureMode = Get-GpuVMCaptureMode -State $state
        if ($guest -and $done['capture'] -eq $captureMode -and -not $restartSunshine) { $prepared['capture'] = $captureMode }
        elseif ($guest) {
            try {
                if ($restartSunshine) { Write-Step 'Sunshine is restarting to pick up the changes' }
                # The mode the guest really uses: with a standard user signed in, WGC stays ddx (the service).
                $effective = $captureMode
                $null = Set-GuestCaptureMode -Name $Name -Credential $guest -Mode $captureMode -Restart:$restartSunshine -Effective ([ref]$effective)
                $captureMode = $effective
                $prepared['capture'] = $captureMode
            }
            catch { Write-Warning "Couldn't set Sunshine's capture: $($_.Exception.Message)" }
        }
        # With WGC, administrator prompts are shown and answered from the app: the guest watcher, once per boot.
        if ($guest -and $captureMode -eq 'wgc') {
            if ($done['adminPrompt']) { $prepared['adminPrompt'] = $true }
            else {
                try {
                    if (Install-GuestAdminPrompt -Name $Name -Credential $guest) { Write-Step 'The VM''s administrator prompts now show in GpuVM' }
                    $prepared['adminPrompt'] = $true
                }
                catch { Write-Warning "Couldn't set up the VM's administrator prompts: $($_.Exception.Message)" }
            }
        }

        $systemDisk = Get-VMHardDiskDrive -VMName $Name | Sort-Object ControllerNumber, ControllerLocation | Select-Object -First 1
        $diskBytes = try { [string](Get-VHD -Path $systemDisk.Path).Size } catch { '' }
        if ($guest) { Invoke-GuestPendingWork -Name $Name -Credential $guest -DiskBytes $diskBytes }

        # The VM's IP is only trusted if it is on the host's network with the VM (see Get-GpuVMEndpoint).
        $endpoint = Get-GpuVMEndpoint -Name $Name
        $address = $endpoint.Address
        $credential = Get-SunshineCredential -State $state
        # Without the guest password GpuVM can't tell whether Windows is still setting itself up; a VM that has been on
        # for a while is past that, so the first-boot message only shows when it can still be the case.
        $firstBoot = -not $guest -and (Get-VM -Name $Name).Uptime.TotalMinutes -lt 15
        $waiting = if ($firstBoot) { 'Waiting for Sunshine (the first start installs Windows and streaming; it can take several minutes)' } else { 'Waiting for Sunshine' }
        Wait-SunshineReady -Address $address -Credential $credential -Message $waiting
        if ($state['config']['streaming']['virtualDisplay']) {
            Set-SunshineVirtualDisplay -Address $address -Credential $credential -OnlyDisplay:([bool]$state['config']['streaming']['disableHyperVVideo']) -Name $Name -GuestCredential $guest
        }

        $clientName = if ($Viewer) { Get-GpuVMViewerClientName } else { $env:COMPUTERNAME }
        if ($Pair -or -not (Test-SunshineClientPaired -Address $address -Credential $credential -ClientName $clientName)) {
            Register-MoonlightPairing -Address $address -Credential $credential -MoonlightPath $moonlight -ClientName $clientName -HostAddress $endpoint.HostAddress -Quiet:$Viewer
            $state = Get-GpuVMState -Name $Name
            $state['streaming']['pairedClient'] = $clientName
            $state['streaming']['pairedAt'] = (Get-Date).ToString('o')
            Save-GpuVMState $state
        }

        # The speaker comes back ~60 s after Windows starts (usbip-win2 reattaches it), well after Sunshine answers
        # (lab 019). If it is still on its way, Moonlight opens now and the speaker is checked once the picture is up.
        $audioLater = [bool]($audioCheck -and $audioCheck.Job.State -eq 'Running')
        if ((Test-GpuVMAudio $state['config']['streaming']) -and -not $audioLater) {
            if ($guest) {
                try {
                    # Always checked: it also attaches the speaker again if Windows lost it.
                    Stop-GuestAudioCheck $audioCheck
                    $audioCheck = $null
                    $installed = Install-GuestAudio -Name $Name -Credential $guest
                    if ($installed) {
                        Wait-SunshineReady -Address $address -Credential $credential -TimeoutSec 120 -Message 'Sunshine is restarting with the new audio'
                    }
                    # VMs from before 0.3 had VB-CABLE; from now on they have the speaker.
                    if ($state['config']['streaming']['audio'] -ne 'usb') {
                        $state = Get-GpuVMState -Name $Name
                        $state['config']['streaming']['audio'] = 'usb'
                        Save-GpuVMState $state
                    }
                    if ($installed -or -not $done['audioSink']) {
                        Set-SunshineAudioSink -Name $Name -GuestCredential $guest -Address $address -Credential $credential
                    }
                    $prepared['audioSink'] = $true
                }
                catch { Write-Warning "Couldn't set up the audio inside the VM: $($_.Exception.Message)" }
            }
            else {
                $sunshineConfig = try { Invoke-SunshineApi -Address $address -Credential $credential -Path '/api/config' } catch { $null }
                if ($sunshineConfig -and "$($sunshineConfig.PSObject.Properties['virtual_sink']?.Value)" -notlike '*GpuVM Audio*') {
                    Write-Warning 'The VM''s audio isn''t ready yet. Save the VM''s Windows password so GpuVM can set it up.'
                }
            }
        }
    }
    finally {
        if (-not $audioLater) { Stop-GuestAudioCheck $audioCheck -TimeoutSec 0; $audioCheck = $null }
        Close-GuestSession -Name $Name
    }

    Write-Step "Opening at $($client['resolution']) and $(Resolve-GpuVMStreamFps $client['fps']) FPS"
    if ($Viewer) {
        $state = Get-GpuVMState -Name $Name
        $state['lastOpenedAt'] = (Get-Date).ToString('o')
        if ($boot) { $state['guestPrepared'] = $prepared }
        Save-GpuVMState $state
        if (-not $audioLater) { Stop-GuestAudioCheck $audioCheck -TimeoutSec 0 }
        else { Write-Warning 'The VM''s audio will be ready in a few seconds or the next time you open it.'; Stop-GuestAudioCheck $audioCheck -TimeoutSec 0 }
        # The app waits for the viewer's first picture before the button goes back to "Abrir".
        Write-Step 'Connecting the picture'
        return [pscustomobject]@{
            viewerLaunch = [pscustomobject]@{
                arguments = @(Get-MoonlightStreamArguments -Address $address -Client $client)
                monitor   = $target
            }
        }
    }
    $launched = Get-Date
    # Moonlight runs as the signed-in user, not as administrator: it talks to a server the guest controls.
    Start-UnelevatedProcess -FilePath $moonlight -ArgumentList (Get-MoonlightStreamArguments -Address $address -Client $client) | Out-Null
    if ($target) {
        try { Move-MoonlightToMonitor -Since $launched -Monitor $target }
        catch { Write-Warning "Couldn't move Moonlight to $($target['name']): $($_.Exception.Message)" }
    }
    # For the home screen's "continue where you left off", and what is already done in this boot.
    $state = Get-GpuVMState -Name $Name
    $state['lastOpenedAt'] = (Get-Date).ToString('o')
    if ($boot) { $state['guestPrepared'] = $prepared }
    Save-GpuVMState $state
    try {
        Wait-MoonlightStream -Since $launched
        $null = Invoke-AgentScreenRefresh -Name $Name
        if ($audioLater) {
            Write-Step 'Setting up the audio'
            Stop-GuestAudioCheck $audioCheck
            $audioCheck = $null
            try {
                $null = Install-GuestAudio -Name $Name -Credential $guest
                # Changing Sunshine's sink now would restart it and cut the picture: it is only checked, and fixed on the
                # next open (audioSink stays unmarked for this boot).
                $sink = Get-GuestAudioSink -Name $Name -Credential $guest
                $config = Invoke-SunshineApi -Address $address -Credential $credential -Path '/api/config'
                if (-not $sink -or "$($config.PSObject.Properties['virtual_sink']?.Value)" -ne $sink) {
                    Write-Warning 'The VM''s audio will be ready the next time you open it.'
                }
            }
            catch { Write-Warning "Couldn't set up the audio inside the VM: $($_.Exception.Message)" }
        }
    }
    finally { Stop-GuestAudioCheck $audioCheck -TimeoutSec 0 }
}
