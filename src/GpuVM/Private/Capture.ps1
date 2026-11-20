# Sunshine's capture mode inside the guest (guest/capture-mode.ps1). "wgc" by default: the picture shows ~2.6 s after
# connecting where DDX restarts until the screen changes (labs 023-024), and it streams exclusive-fullscreen games;
# administrator prompts, which it can't stream, are answered from the app (AdminPrompt.ps1). "ddx" when chosen.

function Get-GpuVMCaptureMode {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    # An agent machine always uses the service (SYSTEM): `agent` must never own Sunshine. DDX gives no picture on its
    # virtual display (lab 055), so it captures with WGC through GpuVM's Sunshine fork, whose helper runs as `agent`
    # and holds nothing secret (Install-GuestSunshineCapture). Without the helper the guest falls back to ddx.
    if ([string]$State['use'] -eq 'agent') { return 'wgc-service' }
    $streaming = if ($State['config'] -is [System.Collections.IDictionary]) { $State['config']['streaming'] }
    if ($streaming -and $streaming.Contains('captureMode') -and $streaming['captureMode'] -eq 'ddx') { 'ddx' } else { 'wgc' }
}

# Applies the mode in the running guest. The script is sent every time, so it also works on older VMs.
# Returns $true when Sunshine was restarted.
function Set-GuestCaptureMode {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][ValidateSet('ddx', 'wgc', 'wgc-service')][string]$Mode,
        # Restarts Sunshine even if the mode is the same (after a display change; see Connect-GpuVM).
        [switch]$Restart,
        # Set to the mode the guest really uses: ddx when WGC was asked for but a standard user is signed in, or
        # wgc-service without the fork's helper.
        [ref]$Effective
    )
    $code = Get-Content -Raw -LiteralPath (Get-RepoPath 'guest\capture-mode.ps1')
    $raw = Invoke-Guest -Name $Name -Credential $Credential -ArgumentList $code, $Mode, ([bool]$Restart) -ScriptBlock {
        param($code, $mode, $restart)
        & ([scriptblock]::Create($code)) -Mode $mode -Restart:$restart
    }
    $answer = [string](@($raw)[-1])
    if ($Effective) { $Effective.Value = $Mode }
    if ($answer -like 'standard-*') {
        # The signed-in user isn't an administrator: Sunshine stays the service's (guest\capture-mode.ps1).
        if ($Effective) { $Effective.Value = 'ddx' }
        if ($Mode -eq 'wgc') { Write-Step 'Windows'' user isn''t an administrator: Sunshine captures as a service' }
        $answer = $answer.Substring(9)
    }
    elseif ($answer -like 'nofork-*') {
        # No helper of GpuVM's Sunshine fork in the guest: desktop duplication, which can stay black (lab 055).
        if ($Effective) { $Effective.Value = 'ddx' }
        Write-Warning 'GpuVM''s Sunshine capture helper isn''t in this machine: the picture can stay black until the agent is installed again.'
        $answer = $answer.Substring(7)
    }
    switch ($answer) {
        'changed' {
            if (-not $Restart) {
                Write-Step $(switch ($Mode) {
                        'wgc' { 'Sunshine is restarting with exclusive fullscreen capture' }
                        'wgc-service' { 'Sunshine is restarting with its capture helper' }
                        default { 'Sunshine is restarting with standard capture' }
                    })
            }
            $true
        }
        'unchanged' { $false }
        'nosession' { throw 'No one is signed in on the VM''s screen.' }
        default { throw 'Sunshine isn''t installed in the VM.' }
    }
}
