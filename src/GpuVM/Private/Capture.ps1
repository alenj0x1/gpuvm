# Sunshine's capture mode inside the guest (guest/capture-mode.ps1). Sunshine is always the service (SYSTEM) and
# GpuVM's own Sunshine fork on every machine, whatever its use. "wgc" by default: the fork's helper captures as the
# signed-in user (holding nothing secret), the picture shows at once and exclusive-fullscreen games stream;
# administrator prompts, which it can't stream, are answered from the app (AdminPrompt.ps1). "ddx" when chosen: it
# streams those prompts, but on the virtual display over GPU-P it loses access after every frame (lab 055).

function Get-GpuVMCaptureMode {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    $streaming = if ($State['config'] -is [System.Collections.IDictionary]) { $State['config']['streaming'] }
    if ($streaming -and $streaming.Contains('captureMode') -and $streaming['captureMode'] -eq 'ddx') { 'ddx' } else { 'wgc' }
}

# Applies the mode in the running guest. The script is sent every time, so it also works on older VMs (it removes
# the user-mode Sunshine task of machines from before the fork). Returns $true when Sunshine was restarted.
function Set-GuestCaptureMode {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][ValidateSet('ddx', 'wgc')][string]$Mode,
        # Restarts Sunshine even if the mode is the same (after a display change; see Connect-GpuVM).
        [switch]$Restart,
        # Set to the mode the guest really uses: ddx when wgc was asked for but the fork's helper isn't there.
        [ref]$Effective
    )
    $code = Get-Content -Raw -LiteralPath (Get-RepoPath 'guest\capture-mode.ps1')
    $raw = Invoke-Guest -Name $Name -Credential $Credential -ArgumentList $code, $Mode, ([bool]$Restart) -ScriptBlock {
        param($code, $mode, $restart)
        & ([scriptblock]::Create($code)) -Mode $mode -Restart:$restart
    }
    $answer = [string](@($raw)[-1])
    if ($Effective) { $Effective.Value = $Mode }
    if ($answer -like 'nofork-*') {
        # No helper of GpuVM's Sunshine fork in the guest: desktop duplication, which can stay black (lab 055).
        if ($Effective) { $Effective.Value = 'ddx' }
        Write-Warning 'GpuVM''s Sunshine capture helper isn''t in this machine: the picture can stay black until GpuVM installs it again.'
        $answer = $answer.Substring(7)
    }
    switch ($answer) {
        'changed' {
            if (-not $Restart) {
                Write-Step $(if ($Mode -eq 'wgc') { 'Sunshine is restarting with its capture helper' } else { 'Sunshine is restarting with standard capture' })
            }
            $true
        }
        'unchanged' { $false }
        default { throw 'Sunshine isn''t installed in the VM.' }
    }
}
