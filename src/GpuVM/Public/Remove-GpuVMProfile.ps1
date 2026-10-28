function Remove-GpuVMProfile {
    <#
    .SYNOPSIS
    Deletes a user profile. Built-in profiles and profiles other profiles extend are kept.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name)
    $dir = Get-UserProfileDirectory
    $path = Join-Path $dir "$Name.json"
    if (-not (Test-Path -LiteralPath $path)) { throw "No existe el perfil '$Name' (los incluidos no se pueden borrar)." }
    $children = @(Get-ChildItem $dir -Filter *.json | Where-Object { (Read-JsonFile $_.FullName)['extends'] -eq $Name })
    if ($children) { throw "Lo usan otros perfiles: $(($children.BaseName) -join ', ')." }
    Remove-Item -LiteralPath $path
}
