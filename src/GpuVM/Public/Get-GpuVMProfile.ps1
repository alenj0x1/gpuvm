function Get-GpuVMProfile {
    <#
    .SYNOPSIS
    Without a name, lists the profiles. With a name, shows the resolved profile (inheritance and override applied).
    #>
    [CmdletBinding()]
    param(
        [string]$Name,
        [hashtable]$Override
    )
    if ($Name) { return Resolve-GpuVMProfile -Name $Name -Override $Override }
    Get-ChildItem (Get-ProfileDirectory) -Filter *.json | ForEach-Object {
        $data = Read-JsonFile $_.FullName
        [pscustomobject]@{
            Name        = $_.BaseName
            Extends     = $data['extends']
            Description = $data['description']
        }
    }
}
