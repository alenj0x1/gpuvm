function Get-GpuVMBase {
    <#
    .SYNOPSIS
    The Windows bases: an ISO's edition applied once, so new VMs with it are copies instead of a new install from the
    ISO. Deleting one only means the next VM with that edition applies it again.
    #>
    [CmdletBinding()]
    param()
    Assert-Admin
    $root = Get-BaseRoot
    if (-not (Test-Path -LiteralPath $root)) { return }
    foreach ($dir in Get-ChildItem -LiteralPath $root -Directory | Where-Object Name -match '^[0-9a-f]{16}$') {
        $base = Read-WindowsBase -Key $dir.Name
        if (-not $base) { continue }
        [ordered]@{
            key       = $base['key']
            edition   = $base['edition']
            language  = $base['language']
            createdAt = $base['createdAt']
            fileGB    = [math]::Round((Get-Item -LiteralPath $base['vhdPath']).Length / 1GB, 1)
        }
    }
}
