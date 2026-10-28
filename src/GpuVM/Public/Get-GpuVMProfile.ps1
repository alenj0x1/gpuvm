function Get-GpuVMProfile {
    <#
    .SYNOPSIS
    Without a name, lists the built-in and user profiles with their main values. With a name, shows the
    resolved profile (inheritance and override applied).
    #>
    [CmdletBinding()]
    param(
        [string]$Name,
        [hashtable]$Override
    )
    if ($Name) { return Resolve-GpuVMProfile -Name $Name -Override $Override }
    $files = @(
        Get-ChildItem (Get-ProfileDirectory) -Filter *.json | ForEach-Object { @{ File = $_; BuiltIn = $true } }
        $userDir = Get-UserProfileDirectory
        if (Test-Path -LiteralPath $userDir) {
            Get-ChildItem $userDir -Filter *.json | ForEach-Object { @{ File = $_; BuiltIn = $false } }
        }
    )
    foreach ($item in $files) {
        $data = Read-JsonFile $item.File.FullName
        $settings = try { ConvertTo-ProfileSettings (Resolve-GpuVMProfile -Name $item.File.BaseName) } catch { $null }
        [pscustomobject]@{
            Name        = $item.File.BaseName
            Extends     = $data['extends']
            Description = $data['description']
            BuiltIn     = $item.BuiltIn
            Settings    = $settings
        }
    }
}

# The values the app shows and edits, flattened from a resolved profile.
function ConvertTo-ProfileSettings {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $client = if ($Config['streaming']) { $Config['streaming']['client'] } else { $null }
    [ordered]@{
        cpu         = $Config['vm']['cpu']['count']
        memoryGB    = $Config['vm']['memoryGB']
        gpuPercent  = $Config['gpu']['allocationPercent']
        diskGB      = $Config['vm']['disk']['sizeGB']
        diskType    = $Config['vm']['disk']['type']
        iso         = if ($Config.Contains('iso')) { $Config['iso'] } else { $null }
        apps        = @(if ($Config['guest'].Contains('apps')) { $Config['guest']['apps'] })
        resolution  = if ($client) { $client['resolution'] } else { $null }
        fps         = if ($client) { $client['fps'] } else { $null }
        displayMode = if ($client -and $client.Contains('displayMode') -and $client['displayMode']) { $client['displayMode'] } else { 'fullscreen' }
    }
}
