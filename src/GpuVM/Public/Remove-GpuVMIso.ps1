function Remove-GpuVMIso {
    <#
    .SYNOPSIS
    Removes an ISO from the library. The file itself is not deleted.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    Save-IsoLibrary @(Read-IsoLibrary | Where-Object { $_['path'] -ne $full })
}
