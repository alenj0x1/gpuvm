function Add-GpuVMIso {
    <#
    .SYNOPSIS
    Adds a Windows ISO to the library, so the "Create machine" wizard offers it from any folder.
    .EXAMPLE
    Add-GpuVMIso -Path D:\ISOs\Win11_24H2.iso
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ([IO.Path]::GetExtension($Path) -ne '.iso' -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "No se encontró la imagen $Path."
    }
    Register-GpuVMIsoUse -Path $Path
}
