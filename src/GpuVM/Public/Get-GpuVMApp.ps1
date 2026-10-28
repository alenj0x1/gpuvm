function Get-GpuVMApp {
    <#
    .SYNOPSIS
    The apps GpuVM can install inside a VM (apps/catalog.json).
    #>
    [CmdletBinding()]
    param()
    $catalog = Get-AppCatalog
    foreach ($id in $catalog.Keys) {
        [ordered]@{ id = $id; name = $catalog[$id]['name']; signer = $catalog[$id]['signer'] }
    }
}
