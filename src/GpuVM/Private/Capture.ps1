# Sunshine's capture inside the guest (guest/capture-mode.ps1). Sunshine is always the service (SYSTEM) and GpuVM's
# own Sunshine fork on every machine, whatever its use, and it captures one way: Windows.Graphics.Capture through the
# fork's helper, which captures as the signed-in user (holding nothing secret), so the picture shows at once and
# exclusive-fullscreen games stream; administrator prompts, which it can't stream, are answered from the app
# (AdminPrompt.ps1). Desktop duplication ("ddx") was an option until 2026-11-21: on the virtual display over GPU-P it
# loses access after every frame (lab 055).

# Makes sure the running guest captures that way. The script is sent every time, so it also works on older VMs (it
# removes the user-mode Sunshine task of machines from before the fork, and a ddx choice they kept). Returns $true
# when Sunshine was restarted.
function Set-GuestCaptureMode {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        # Restarts Sunshine even if nothing changed (after a display change; see Connect-GpuVM).
        [switch]$Restart
    )
    $code = Get-Content -Raw -LiteralPath (Get-RepoPath 'guest\capture-mode.ps1')
    $raw = Invoke-Guest -Name $Name -Credential $Credential -ArgumentList $code, ([bool]$Restart) -ScriptBlock {
        param($code, $restart)
        & ([scriptblock]::Create($code)) -Restart:$restart
    }
    $answer = [string](@($raw)[-1])
    if ($answer -like 'nofork-*') {
        # No helper of GpuVM's Sunshine fork in the guest: Sunshine falls back to desktop duplication, which can stay
        # black (lab 055), until the fork is installed again (Sync-GuestSunshineFork).
        Write-Warning 'GpuVM''s Sunshine capture helper isn''t in this machine: the picture can stay black until GpuVM installs it again.'
        $answer = $answer.Substring(7)
    }
    switch ($answer) {
        'changed' {
            if (-not $Restart) {
                Write-Step 'Sunshine is restarting with its capture helper'
            }
            $true
        }
        'unchanged' { $false }
        default { throw 'Sunshine isn''t installed in the VM.' }
    }
}
