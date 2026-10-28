function Remove-GpuVMDisk {
    <#
    .SYNOPSIS
    Deletes a disk that no VM uses, with its folder. Cannot be undone.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name)
    Assert-Admin
    $root = Get-GpuVMDefaultRoot
    $dir = Join-Path $root $Name
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "No hay un disco llamado '$Name' en $root." }
    $inUse = Get-VM | Get-VMHardDiskDrive | Where-Object { $_.Path -and [IO.Path]::GetFullPath($_.Path).StartsWith("$dir\", [StringComparison]::OrdinalIgnoreCase) }
    if ($inUse) { throw "El disco lo usa la VM '$($inUse[0].VMName)'; elimina primero la VM." }
    # A registered VM keeps its configuration in that folder even with its disk detached.
    $owner = Get-VM | Where-Object { $_.Name -eq $Name -or ($_.ConfigurationLocation -and [IO.Path]::GetFullPath($_.ConfigurationLocation).StartsWith("$dir\", [StringComparison]::OrdinalIgnoreCase)) } | Select-Object -First 1
    if ($owner) { throw "La carpeta pertenece a la VM '$($owner.Name)'; elimina primero la VM." }
    if ((Get-Item -LiteralPath $dir).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$dir es un enlace; no se borra." }
    if (-not $PSCmdlet.ShouldProcess($dir, 'Borrar el disco y su carpeta')) { return }
    Remove-Item -LiteralPath $dir -Recurse -Force
}
