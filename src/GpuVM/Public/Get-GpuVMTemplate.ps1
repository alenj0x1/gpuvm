function Get-GpuVMTemplate {
    <#
    .SYNOPSIS
    The saved templates: where each one came from, its size and the VMs built on it.
    #>
    [CmdletBinding()]
    param()
    Assert-Admin
    $root = Get-TemplateRoot
    if (-not (Test-Path -LiteralPath $root)) { return }
    foreach ($dir in Get-ChildItem -LiteralPath $root -Directory | Where-Object Name -match '^[\w-]{1,40}$') {
        $meta = try { Read-GpuVMTemplate -Name $dir.Name } catch { $null }
        if (-not $meta) { continue }
        $guest = $meta['config']['guest']
        [ordered]@{
            name      = $meta['name']
            fromVM    = $meta['fromVM']
            createdAt = $meta['createdAt']
            edition   = $meta['edition']
            sizeGB    = $meta['sizeGB']
            fileGB    = [math]::Round((Get-Item -LiteralPath $meta['vhdPath']).Length / 1GB, 1)
            cleanup   = if ($guest.Contains('cleanup') -and $guest['cleanup']) { $guest['cleanup'] } else { 'none' }
            usedBy    = @(Get-TemplateChildVM -VhdPath $meta['vhdPath'])
        }
    }
}
