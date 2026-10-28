function Get-GpuVMIsoList {
    <#
    .SYNOPSIS
    Windows ISOs for the "Create machine" wizard: first the ones already used or added (most recent first),
    then the ones found in Downloads and Desktop.
    #>
    [CmdletBinding()]
    param()
    $seen = @{}
    foreach ($entry in Read-IsoLibrary) {
        $file = Get-Item -LiteralPath $entry['path'] -ErrorAction SilentlyContinue
        $seen[$entry['path']] = $true
        [ordered]@{
            path       = $entry['path']
            name       = Split-Path $entry['path'] -Leaf
            sizeGB     = if ($file) { [math]::Round($file.Length / 1GB, 1) } else { 0 }
            modified   = if ($file) { $file.LastWriteTime.ToString('o') } else { '' }
            remembered = $true
            missing    = -not $file
            lastUsed   = $entry['lastUsed']
            usedBy     = @($entry['usedBy'])
        }
    }
    $dirs = @(
        (Join-Path $env:USERPROFILE 'Downloads')
        (Join-Path $env:USERPROFILE 'Desktop')
    )
    foreach ($dir in $dirs | Where-Object { Test-Path $_ }) {
        Get-ChildItem $dir -Filter *.iso -File -ErrorAction SilentlyContinue | Where-Object { -not $seen[$_.FullName] } | ForEach-Object {
            [ordered]@{
                path       = $_.FullName
                name       = $_.Name
                sizeGB     = [math]::Round($_.Length / 1GB, 1)
                modified   = $_.LastWriteTime.ToString('o')
                remembered = $false
                missing    = $false
                lastUsed   = $null
                usedBy     = @()
            }
        }
    }
}
