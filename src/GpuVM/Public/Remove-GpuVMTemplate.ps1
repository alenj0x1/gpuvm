function Remove-GpuVMTemplate {
    <#
    .SYNOPSIS
    Deletes a template. Refused while a VM's disk is built on it (that VM would lose its Windows).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name)
    Assert-Admin
    $meta = Read-GpuVMTemplate -Name $Name
    $children = @(Get-TemplateChildVM -VhdPath $meta['vhdPath'])
    if ($children) { throw "La plantilla '$Name' la usan $($children -join ', '); elimina esas máquinas primero." }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Eliminar plantilla')) { return }
    (Get-Item -LiteralPath $meta['vhdPath']).IsReadOnly = $false
    Remove-Item -LiteralPath $meta['dir'] -Recurse -Force
    Write-Step "Plantilla '$Name' eliminada"
}
