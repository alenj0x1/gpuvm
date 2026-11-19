# Sunshine's capture mode inside the guest (guest/capture-mode.ps1). "wgc" by default: the picture shows ~2.6 s after
# connecting where DDX restarts until the screen changes (labs 023-024), and it streams exclusive-fullscreen games;
# administrator prompts, which it can't stream, are answered from the app (AdminPrompt.ps1). "ddx" when chosen.

function Get-GpuVMCaptureMode {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    $streaming = $State['config']['streaming']
    # An agent machine always uses the service (SYSTEM): WGC runs Sunshine as the signed-in user, which there is the
    # agent's standard account. It can't run Sunshine (no picture: lab 052) and must never own it.
    if ([string]$State['use'] -eq 'agent') { return 'ddx' }
    if ($streaming -and $streaming.Contains('captureMode') -and $streaming['captureMode'] -eq 'ddx') { 'ddx' } else { 'wgc' }
}

# Applies the mode in the running guest. The script is sent every time, so it also works on older VMs.
# Returns $true when Sunshine was restarted.
function Set-GuestCaptureMode {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][ValidateSet('ddx', 'wgc')][string]$Mode,
        # Restarts Sunshine even if the mode is the same (after a display change; see Connect-GpuVM).
        [switch]$Restart,
        # Set to the mode the guest really uses: ddx when WGC was asked for but a standard user is signed in.
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
    switch ($answer) {
        'changed' {
            if (-not $Restart) { Write-Step $(if ($Mode -eq 'wgc') { 'Sunshine is restarting with exclusive fullscreen capture' } else { 'Sunshine is restarting with standard capture' }) }
            $true
        }
        'unchanged' { $false }
        'nosession' { throw 'No one is signed in on the VM''s screen.' }
        default { throw 'Sunshine isn''t installed in the VM.' }
    }
}
