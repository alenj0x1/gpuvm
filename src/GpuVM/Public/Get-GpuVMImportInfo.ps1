function Get-GpuVMImportInfo {
    <#
    .SYNOPSIS
    What a .gpuvm file holds, read from its manifest without unpacking the disk: the machine's name (and a free name
    to import it as), Windows edition, user, apps, when it was exported and how much it takes.
    .EXAMPLE
    Get-GpuVMImportInfo -Path D:\Copias\win10.gpuvm
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Assert-Admin
    $archive = Open-TransferArchive -Path $Path
    try {
        $m = $archive.Manifest
        $base = if ($m['name']) { $m['name'] } else { 'importada' }
        [ordered]@{
            path          = [IO.Path]::GetFullPath($Path)
            name          = $m['name']
            freeName      = Get-FreeGpuVMName -Base $base
            edition       = $m['edition']
            user          = $m['user']
            installedApps = @($m['installedApps'])
            exportedAt    = $m['exportedAt']
            diskGB        = [math]::Round($m['disk']['bytes'] / 1GB, 1)
            fileGB        = [math]::Round($archive.Length / 1GB, 1)
            freeGB        = Get-DriveFreeGB (Get-GpuVMDefaultRoot)
        }
    }
    finally { $archive.Zip.Dispose() }
}
