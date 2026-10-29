function Get-GpuVMApp {
    <#
    .SYNOPSIS
    The apps GpuVM can install inside a VM (apps/catalog.json).
    #>
    [CmdletBinding()]
    param()
    $catalog = Get-AppCatalog
    $categories = Get-AppCategory
    foreach ($id in $catalog.Keys) {
        $category = $catalog[$id]['category']
        [ordered]@{
            id = $id; name = $catalog[$id]['name']; signer = $catalog[$id]['signer']
            category = $category; categoryName = $categories[$category]
        }
    }
}
