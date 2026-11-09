function Remove-GpuVMBase {
    <#
    .SYNOPSIS
    Deletes a Windows base to free its space. No VM depends on it: the next one with that edition applies it again.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{16}$')][string]$Key)
    Assert-Admin
    $base = Read-WindowsBase -Key $Key
    if (-not $base) { throw 'Ese Windows preparado ya no existe.' }
    if ((Get-VHD -Path $base['vhdPath'] -ErrorAction SilentlyContinue).Attached) { throw 'Se está usando para crear una máquina; espera a que termine.' }
    if (-not $PSCmdlet.ShouldProcess($base['edition'], 'Eliminar Windows preparado')) { return }
    (Get-Item -LiteralPath $base['vhdPath']).IsReadOnly = $false
    Remove-Item -LiteralPath $base['dir'] -Recurse -Force
    Write-Step "Windows preparado eliminado"
}
