# Sunshine's capture mode inside the guest (guest/capture-mode.ps1): "ddx" by default, "wgc" for exclusive fullscreen.

function Get-GpuVMCaptureMode {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    $streaming = $State['config']['streaming']
    if ($streaming -and $streaming.Contains('captureMode') -and $streaming['captureMode'] -eq 'wgc') { 'wgc' } else { 'ddx' }
}

# Applies the mode in the running guest. The script is sent every time, so it also works on older VMs.
# Returns $true when Sunshine was restarted.
function Set-GuestCaptureMode {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][ValidateSet('ddx', 'wgc')][string]$Mode
    )
    $code = Get-Content -Raw -LiteralPath (Get-RepoPath 'guest\capture-mode.ps1')
    $raw = Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ArgumentList $code, $Mode -ScriptBlock {
        param($code, $mode)
        & ([scriptblock]::Create($code)) -Mode $mode
    }
    switch ([string](@($raw)[-1])) {
        'changed' { Write-Step $(if ($Mode -eq 'wgc') { 'Sunshine se reinicia con la captura de pantalla completa exclusiva' } else { 'Sunshine se reinicia con la captura estándar' }); $true }
        'unchanged' { $false }
        'nosession' { throw 'No hay una sesión iniciada en la pantalla de la VM.' }
        default { throw 'Sunshine no está instalado en la VM.' }
    }
}
