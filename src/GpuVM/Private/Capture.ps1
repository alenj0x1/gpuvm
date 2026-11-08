# Sunshine's capture mode inside the guest (guest/capture-mode.ps1). "wgc" by default: the picture shows ~2.6 s after
# connecting where DDX restarts until the screen changes (labs 023-024), and it streams exclusive-fullscreen games;
# administrator prompts, which it can't stream, are answered from the app (AdminPrompt.ps1). "ddx" when chosen.

function Get-GpuVMCaptureMode {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    $streaming = $State['config']['streaming']
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
        [switch]$Restart
    )
    $code = Get-Content -Raw -LiteralPath (Get-RepoPath 'guest\capture-mode.ps1')
    $raw = Invoke-Guest -Name $Name -Credential $Credential -ArgumentList $code, $Mode, ([bool]$Restart) -ScriptBlock {
        param($code, $mode, $restart)
        & ([scriptblock]::Create($code)) -Mode $mode -Restart:$restart
    }
    switch ([string](@($raw)[-1])) {
        'changed' {
            if (-not $Restart) { Write-Step $(if ($Mode -eq 'wgc') { 'Sunshine se reinicia con la captura de pantalla completa exclusiva' } else { 'Sunshine se reinicia con la captura estándar' }) }
            $true
        }
        'unchanged' { $false }
        'nosession' { throw 'No hay una sesión iniciada en la pantalla de la VM.' }
        default { throw 'Sunshine no está instalado en la VM.' }
    }
}
