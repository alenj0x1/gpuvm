function Remove-GpuVMTemplate {
    <#
    .SYNOPSIS
    Deletes a template. Refused while a VM's disk is built on it (that VM would lose its Windows).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name)
    Assert-Admin
    $meta = Read-GpuVMTemplate -Name $Name
    $children = @(Get-TemplateChildVM -VhdPath $meta['layerPaths'])
    if ($children) { throw "The template '$Name' is used by $($children -join ', '); delete those machines first." }
    if (Test-TemplateUpdating -Template $meta) { throw "The template '$Name' is being updated; try again when it is done." }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Delete template')) { return }
    foreach ($path in $meta['layerPaths']) { (Get-Item -LiteralPath $path).IsReadOnly = $false }
    Remove-Item -LiteralPath $meta['dir'] -Recurse -Force
    Write-Step "Template '$Name' deleted"
}
