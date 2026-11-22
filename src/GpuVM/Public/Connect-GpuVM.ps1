function Connect-GpuVM {
    <#
    .SYNOPSIS
    Gets a VM ready to be seen in GpuVM's viewer, with the image rendered by the GPU: updates the driver if it changed,
    powers on, waits for Windows and Sunshine, fixes the session and display, pairs the viewer, and returns the stream
    arguments ({ viewerLaunch }) for the app to open the viewer itself. Machines open only in GpuVM's viewer.
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
        # Accepted for the app's calls; machines open only in GpuVM's viewer.
        [switch]$Viewer
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    if (-not $state['streaming']) { throw "The VM '$Name' was created without streaming." }
    $viewerPath = Get-GpuVMViewerPath
    if (-not $viewerPath) { throw 'GpuVM''s viewer isn''t installed. Install GpuVM again.' }
    Initialize-GpuVMRoot -Path $state['config']['vm']['root']

    $vm = Get-VM -Name $Name
    if ($vm.State -eq 'Off') {
        # While the VM is off: a stale driver means a black screen or code 43.
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
        Update-GpuVMNetworkIsolation -Name $Name -State $state
        if ($vm.State -eq 'Paused') { Resume-VM -Name $Name }
    }

    $guest = Get-GpuVMGuestCredential -State $state
    if ($guest) {
        $bootMessage = if ($state.Contains('updatesPending') -and $state['updatesPending']) { 'Finishing updates' } else { 'Waiting for Windows' }
        Wait-GuestReady -Name $Name -Credential $guest -BootMessage $bootMessage
        Open-GuestSession -Name $Name -Credential $guest
        # A copy of an agent template with its agent pending has no automatic sign-in until the agent is installed.
        $agentPending = [string]$state['use'] -eq 'agent' -and $state['agent'] -is [System.Collections.IDictionary] -and $state['agent']['pending']
        if (-not $agentPending) { $null = Wait-GuestSignIn -Name $Name -Credential $guest }
        # An imported disk is never mounted on this PC: its streaming identity is reset inside the VM.
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
        if ($state.Contains('agentRemovalPending') -and $state['agentRemovalPending']) {
            if (Complete-GuestAgentRemoval -Name $Name -Credential $guest) {
                $state = Get-GpuVMState -Name $Name
                $state.Remove('agentRemovalPending')
                Save-GpuVMState $state
            }
        }
        if ([string]$state['use'] -eq 'agent') {
            try { $null = Enable-GuestHyperVVideo -Name $Name -Credential $guest }
            catch { Write-Warning "Couldn't turn the machine's Hyper-V display on: $($_.Exception.Message)" }
        }
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
        $boot = if ($guest) { try { Get-GuestBootTime -Name $Name -Credential $guest } catch { '' } } else { '' }
        $done = if ($boot -and $state.Contains('guestPrepared') -and $state['guestPrepared'] -and [string]$state['guestPrepared']['boot'] -eq $boot) { $state['guestPrepared'] } else { @{} }
        $prepared = @{ boot = $boot }
        if ($guest -and -not $done.Count -and (Test-GpuVMAudio $state['config']['streaming'])) {
            $audioCheck = Start-GuestAudioCheck -Name $Name -Credential $guest
        }

        # Display first: a display change after Sunshine tested its encoders makes it test them all again (10-15 s of black).
        $override = @{}
        if ($Resolution) { $override['resolution'] = $Resolution }
        if ($Fps) { $override['fps'] = $Fps }
        if ($BitrateKbps) { $override['bitrateKbps'] = $BitrateKbps }
        if ($Codec) { $override['codec'] = $Codec }
        if ($App) { $override['app'] = $App }
        $client = Merge-Hashtable -Base $state['config']['streaming']['client'] -Override $override
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
            $mode = "$($client['resolution'])@$(Resolve-GpuVMStreamFps $client['fps'])"
            if ([string]$state['use'] -eq 'agent') {
                try {
                    if ((Sync-GuestAgentDisplayMode -Name $Name -Credential $guest -Mode $mode) -and $mode -match '^(\d+)x(\d+)@(\d+)$') {
                        $null = Set-GuestVddPreferredMode -Name $Name -Credential $guest -Width $Matches[1] -Height $Matches[2] -Hz $Matches[3]
                    }
                }
                catch { Write-Warning "Couldn't tell the agent the viewer's display mode: $($_.Exception.Message)" }
            }
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
        if ($guest -and -not ($state.Contains('gamepad') -and $state['gamepad'])) {
            try {
                if (Install-GuestGamepad -Name $Name -Credential $guest) { $restartSunshine = $true }
                $state = Get-GpuVMState -Name $Name
                $state['gamepad'] = 'vigembus'
                Save-GpuVMState $state
            }
            catch { Write-Warning "Couldn't set up controller support in the VM: $($_.Exception.Message)" }
        }
        if ($guest) {
            try { if ((Sync-GuestSunshineFork -Name $Name -Credential $guest) -eq 'installed') { $done.Remove('capture') } }
            catch { Write-Warning "Couldn't install GpuVM's Sunshine in the VM: $($_.Exception.Message)" }
            $state = Get-GpuVMState -Name $Name
        }
        if ($guest -and $done['capture'] -eq 'wgc' -and -not $restartSunshine) { $prepared['capture'] = 'wgc' }
        elseif ($guest) {
            try {
                if ($restartSunshine) { Write-Step 'Sunshine is restarting to pick up the changes' }
                $null = Set-GuestCaptureMode -Name $Name -Credential $guest -Restart:$restartSunshine
                $prepared['capture'] = 'wgc'
            }
            catch { Write-Warning "Couldn't set Sunshine's capture: $($_.Exception.Message)" }
        }
        if ($guest) {
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

        $endpoint = Get-GpuVMEndpoint -Name $Name
        $address = $endpoint.Address
        $credential = Get-SunshineCredential -State $state
        $firstBoot = -not $guest -and (Get-VM -Name $Name).Uptime.TotalMinutes -lt 15
        $waiting = if ($firstBoot) { 'Waiting for Sunshine (the first start installs Windows and streaming; it can take several minutes)' } else { 'Waiting for Sunshine' }
        Wait-SunshineReady -Address $address -Credential $credential -Message $waiting
        if ($state['config']['streaming']['virtualDisplay']) {
            Set-SunshineVirtualDisplay -Address $address -Credential $credential -OnlyDisplay:([bool]$state['config']['streaming']['disableHyperVVideo'] -or [string]$state['use'] -eq 'agent') -Name $Name -GuestCredential $guest
        }

        $clientName = Get-GpuVMViewerClientName
        if ($Pair -or -not (Test-SunshineClientPaired -Address $address -Credential $credential -ClientName $clientName)) {
            Register-MoonlightPairing -Address $address -Credential $credential -MoonlightPath $viewerPath -ClientName $clientName -HostAddress $endpoint.HostAddress -Quiet
            $state = Get-GpuVMState -Name $Name
            $state['streaming']['pairedClient'] = $clientName
            $state['streaming']['pairedAt'] = (Get-Date).ToString('o')
            Save-GpuVMState $state
        }
        elseif (-not $state['streaming']['pairedClient']) {
            $state = Get-GpuVMState -Name $Name
            $state['streaming']['pairedClient'] = $clientName
            $state['streaming']['pairedAt'] = (Get-Date).ToString('o')
            Save-GpuVMState $state
        }

        $audioLater = [bool]($audioCheck -and $audioCheck.Job.State -eq 'Running')
        if ((Test-GpuVMAudio $state['config']['streaming']) -and -not $audioLater) {
            if ($guest) {
                try {
                    Stop-GuestAudioCheck $audioCheck
                    $audioCheck = $null
                    $installed = Install-GuestAudio -Name $Name -Credential $guest
                    if ($installed) {
                        Wait-SunshineReady -Address $address -Credential $credential -TimeoutSec 120 -Message 'Sunshine is restarting with the new audio'
                    }
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
    $state = Get-GpuVMState -Name $Name
    $state['lastOpenedAt'] = (Get-Date).ToString('o')
    if ($boot) { $state['guestPrepared'] = $prepared }
    Save-GpuVMState $state
    if (-not $audioLater) { Stop-GuestAudioCheck $audioCheck -TimeoutSec 0 }
    else { Write-Warning 'The VM''s audio will be ready in a few seconds or the next time you open it.'; Stop-GuestAudioCheck $audioCheck -TimeoutSec 0 }
    Write-Step 'Connecting the picture'
    return [pscustomobject]@{
        viewerLaunch = [pscustomobject]@{
            arguments = @(Get-MoonlightStreamArguments -Address $address -Client $client)
            monitor   = $target
        }
    }
}
