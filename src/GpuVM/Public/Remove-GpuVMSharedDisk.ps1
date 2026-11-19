function Remove-GpuVMSharedDisk {
    <#
    .SYNOPSIS
    Deletes a shared disk and everything on it. Refused while it is attached to a VM.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name)
    Assert-Admin
    $disk = Read-SharedDisk -Name $Name
    $attachment = Get-SharedDiskAttachment -Path $disk['path']
    if ($attachment) { throw "The disk '$Name' is connected to '$($attachment.VMName)'; disconnect it first." }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Delete shared disk')) { return }
    Remove-Item -LiteralPath $disk['path'], ([IO.Path]::ChangeExtension($disk['path'], '.json')) -Force -ErrorAction SilentlyContinue
    Write-Step "Disk '$Name' deleted"
}
