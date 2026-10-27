function Get-GpuVMIsoList {
    <#
    .SYNOPSIS
    Windows ISOs in Downloads and Desktop, for the "Create machine" wizard.
    #>
    [CmdletBinding()]
    param()
    $dirs = @(
        (Join-Path $env:USERPROFILE 'Downloads')
        (Join-Path $env:USERPROFILE 'Desktop')
    )
    foreach ($dir in $dirs | Where-Object { Test-Path $_ }) {
        Get-ChildItem $dir -Filter *.iso -File -ErrorAction SilentlyContinue | ForEach-Object {
            [ordered]@{
                path     = $_.FullName
                name     = $_.Name
                sizeGB   = [math]::Round($_.Length / 1GB, 1)
                modified = $_.LastWriteTime.ToString('o')
            }
        }
    }
}
