function Remove-GpuVMProfile {
    <#
    .SYNOPSIS
    Deletes a user profile. Built-in profiles and profiles other profiles extend are kept.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name)
    $dir = Get-UserProfileDirectory
    $path = Join-Path $dir "$Name.json"
    if (-not (Test-Path -LiteralPath $path)) { throw "The profile '$Name' doesn't exist (built-in ones can't be deleted)." }
    $children = @(Get-ChildItem $dir -Filter *.json | Where-Object { (Read-JsonFile $_.FullName)['extends'] -eq $Name })
    if ($children) { throw "Other profiles use it: $(($children.BaseName) -join ', ')." }
    Remove-Item -LiteralPath $path
}
