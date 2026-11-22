# Policies drop the Microsoft Store source: its agreement prompt would leave a winget run waiting for an answer.

$script:WingetComponents = 'winget', 'winget-dependencies', 'winget-license'

# Bump WingetPolicyVersion when this list changes, so templates and machines get it again.
$script:WingetPolicies = [ordered]@{
    EnableMicrosoftStoreSource                     = 0
    EnableMSAppInstallerProtocol                   = 0
    EnableHashOverride                             = 0
    EnableLocalManifestFiles                       = 0
    EnableLocalArchiveMalwareScanOverride          = 0
    EnableBypassCertificatePinningForMicrosoftStore = 0
    EnableWindowsPackageManagerConfiguration       = 0
}
$script:WingetPolicyVersion = 1

# Only SYSTEM and Administrators can write there, so `agent` can't fake it.
$script:WingetStampKey = 'ProgramData\GpuVM\Agent\winget'

function Get-WingetStampText {
    param([System.Collections.IDictionary]$Manifest = (Get-ComponentManifest))
    foreach ($name in $script:WingetComponents) { if (-not $Manifest.Contains($name)) { return $null } }
    (@($script:WingetComponents | ForEach-Object { "$_=$($Manifest[$_]['sha256'])" }) + "policy=$script:WingetPolicyVersion") -join ';'
}

function Get-WingetStampHash {
    param([System.Collections.IDictionary]$Manifest = (Get-ComponentManifest))
    $text = Get-WingetStampText -Manifest $Manifest
    if (-not $text) { return $null }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text)))
}

# Microsoft's signature, exactly (the organization and the whole subject, not a prefix).
function Test-MicrosoftSignature {
    param([Parameter(Mandatory)][string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $signature.Status -eq 'Valid' -and $signature.SignerCertificate -and
    $signature.SignerCertificate.Subject -eq 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
}

function Get-WingetPackage {
    $manifest = Get-ComponentManifest
    $versions = @($script:WingetComponents | ForEach-Object {
        if (-not $manifest.Contains($_)) { throw "This GpuVM's components don't list $_." }
        [string]$manifest[$_]['version']
    } | Select-Object -Unique)
    if ($versions.Count -ne 1) { throw "winget's components come from different releases ($($versions -join ', ')); update them together." }
    $bundle = Save-GpuVMComponent -Name 'winget' -Manifest $manifest
    $license = Save-GpuVMComponent -Name 'winget-license' -Manifest $manifest
    $zip = Save-GpuVMComponent -Name 'winget-dependencies' -Manifest $manifest
    if (-not (Test-MicrosoftSignature -Path $bundle)) { throw "App Installer's package doesn't carry Microsoft's signature; it isn't used." }

    # Only the x64 packages, by plain names (the zip's hash is pinned, but an entry never picks its own path).
    $dir = Join-Path (Split-Path $zip -Parent) 'x64'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    $deps = try {
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -notmatch '^x64/([\w.-]+\.appx)$') { continue }
            $path = Join-Path $dir $Matches[1]
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $path, $true)
            $path
        }
    }
    finally { $archive.Dispose() }
    if (@($deps).Count -lt 1) { throw "App Installer's dependencies zip has no x64 packages." }
    foreach ($path in $deps) {
        if (-not (Test-MicrosoftSignature -Path $path)) { throw "$(Split-Path $path -Leaf) doesn't carry Microsoft's signature; it isn't used." }
    }
    $files = @(
        @{ Path = $bundle; Role = 'bundle' }
        @{ Path = $license; Role = 'license' }
        foreach ($path in $deps) { @{ Path = $path; Role = 'dependency' } }
    ) | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Name = Split-Path $_.Path -Leaf; Sha256 = (Get-FileSha256 $_.Path).ToUpperInvariant(); Role = $_.Role } }
    [pscustomobject]@{ Files = $files; Stamp = Get-WingetStampText -Manifest $manifest; Version = $versions[0] }
}

function Install-GuestWinget {
    param([Parameter(Mandatory)]$Session)
    $want = Get-WingetStampText
    if (-not $want) { throw "This GpuVM's components don't list winget." }
    $have = Invoke-InAgentSession $Session -ArgumentList "C:\$script:WingetStampKey" -ScriptBlock {
        param($path)
        if (Test-Path -LiteralPath $path -PathType Leaf) { [IO.File]::ReadAllText($path) } else { '' }
    }
    if ([string](@($have)[-1]) -eq $want) { return 'current' }

    $package = Get-WingetPackage
    Write-Step "Installing winget $($package.Version) in the machine"
    $dir = Invoke-InAgentSession $Session -ScriptBlock {
        $dir = Join-Path $env:SystemRoot "Temp\GpuVMWinget-$([guid]::NewGuid().ToString('n'))"
        New-Item -ItemType Directory -Path $dir | Out-Null
        & icacls.exe $dir /setowner '*S-1-5-32-544' /Q | Out-Null
        & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Couldn't restrict $dir." }
        $dir
    }
    $dir = [string](@($dir)[-1])
    try {
        foreach ($file in $package.Files) { Copy-ToAgentSession $Session -Path $file.Path -Destination (Join-Path $dir $file.Name) }
        $list = @($package.Files | ForEach-Object { @{ name = $_.Name; sha256 = $_.Sha256; role = $_.Role } })
        $result = Invoke-InAgentSession $Session -ArgumentList $dir, $list, $want, ([System.Collections.IDictionary]$script:WingetPolicies), "C:\$script:WingetStampKey" -ScriptBlock {
            param($dir, $list, $stamp, $policies, $stampPath)
            $ErrorActionPreference = 'Stop'
            $microsoft = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
            $byRole = @{ bundle = @(); license = @(); dependency = @() }
            foreach ($f in $list) {
                $path = Join-Path $dir $f.name
                # Checked again here: what Windows installs is exactly what this PC verified.
                if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $f.sha256) { throw "$($f.name) isn't the file GpuVM sent." }
                if ($f.role -ne 'license') {
                    $signature = Get-AuthenticodeSignature -LiteralPath $path
                    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -ne $microsoft) { throw "$($f.name) doesn't carry Microsoft's signature." }
                }
                $byRole[$f.role] += $path
            }
            Add-AppxProvisionedPackage -Online -PackagePath $byRole['bundle'][0] -DependencyPackagePath $byRole['dependency'] -LicensePath $byRole['license'][0] | Out-Null
            $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller'
            if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
            foreach ($name in $policies.Keys) { Set-ItemProperty -Path $key -Name $name -Value ([int]$policies[$name]) -Type DWord }
            # The agent's data folder exists (its install made it, SYSTEM and Administrators only); never through a link.
            $parent = Split-Path $stampPath -Parent
            if (-not (Test-Path -LiteralPath $parent)) { throw "$parent doesn't exist: the agent isn't installed." }
            if ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$parent is a link." }
            [IO.File]::WriteAllText($stampPath, $stamp)
            $p = Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'Microsoft.DesktopAppInstaller' | Select-Object -First 1
            if (-not $p) { throw 'App Installer isn''t provisioned after its install.' }
            [string]$p.Version
        }
        Write-Step "winget is provisioned (App Installer $(@($result)[-1]))"
        'installed'
    }
    finally {
        Invoke-InAgentSession $Session -ArgumentList $dir -ScriptBlock { param($dir) Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
