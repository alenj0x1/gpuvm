# A dot can't start a VM name, so <root>\.templates never clashes with VM folders.

function Get-TemplateRoot { Join-Path (Get-GpuVMDefaultRoot) '.templates' }

function Get-TemplateDirectory {
    param([Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name)
    Join-Path (Get-TemplateRoot) $Name
}

# Paths taken from where it really is, never from the file.
function Read-GpuVMTemplate {
    param([Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name)
    $dir = Get-TemplateDirectory -Name $Name
    $metaPath = Join-Path $dir 'template.json'
    if (-not (Test-Path -LiteralPath $metaPath)) { throw "The template '$Name' doesn't exist." }
    $meta = Read-JsonFile $metaPath
    $meta['name'] = $Name
    $meta['dir'] = $dir
    $layers = @(if ($meta['layers']) { $meta['layers'] | ForEach-Object { [string]$_ } } else { "$Name.vhdx" })
    foreach ($layer in $layers) {
        if ($layer -notmatch '^[\w.-]{1,80}\.vhdx$' -or $layer -match '\.\.') { throw "The template '$Name' names a disk GpuVM doesn't use ($layer)." }
    }
    $meta['layerPaths'] = @($layers | ForEach-Object { Join-Path $dir $_ })
    $meta['vhdPath'] = $meta['layerPaths'][-1]
    foreach ($path in $meta['layerPaths']) { if (-not (Test-Path -LiteralPath $path)) { throw "The template '$Name' is missing its disk ($(Split-Path $path -Leaf))." } }
    $meta
}

function Get-TemplateChildVM {
    param([Parameter(Mandatory)][string[]]$VhdPath)
    $full = @($VhdPath | ForEach-Object { [IO.Path]::GetFullPath($_) })
    $disks = [ordered]@{}
    foreach ($drive in Get-VM | Get-VMHardDiskDrive) { if ($drive.Path) { $disks[[IO.Path]::GetFullPath($drive.Path)] = $drive.VMName } }
    foreach ($dir in Get-ChildItem -LiteralPath (Get-GpuVMDefaultRoot) -Directory -ErrorAction SilentlyContinue | Where-Object Name -notlike '.*') {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $dir.FullName 'Virtual Hard Disks') -Filter *.vhdx -File -ErrorAction SilentlyContinue) {
            if (-not $disks.Contains($file.FullName)) { $disks[$file.FullName] = $dir.Name }
        }
    }
    $users = foreach ($path in $disks.Keys) {
        $vhd = Get-VHD -Path $path -ErrorAction SilentlyContinue
        for ($i = 0; $vhd -and $vhd.ParentPath -and $i -lt 16; $i++) {
            if ([IO.Path]::GetFullPath($vhd.ParentPath) -in $full) { $disks[$path]; break }
            $vhd = Get-VHD -Path $vhd.ParentPath -ErrorAction SilentlyContinue
        }
    }
    @($users | Select-Object -Unique)
}

# Sunshine makes a new identity and certificate when they are missing.
function Reset-ClonedGuestIdentity {
    param([Parameter(Mandatory)][string]$WindowsRoot)
    $config = Join-Path $WindowsRoot 'Program Files\Sunshine\config'
    $statePath = Join-Path $config 'sunshine_state.json'
    $pems = @('cacert.pem', 'cakey.pem' | ForEach-Object { Join-Path $config "credentials\$_" })
    # The disk was written by a guest: a planted link must not send these writes to the host.
    foreach ($path in @($statePath) + $pems) { Assert-NoReparsePoint -Root $WindowsRoot -Path $path }
    if (Test-Path -LiteralPath $statePath) {
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -AsHashtable
        if ($state.Contains('root')) { $state.Remove('root') }
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 10))
    }
    foreach ($path in $pems) { if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) } }
    # Never the template's agent secret: each copy gets its own.
    Remove-GuestAgentSecret -WindowsRoot $WindowsRoot
}

# Not inheriting the Virtual Machines group's read access: one VM's worker process can't read another's template or shared disk.
function Protect-GpuVMSharedFolder {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Path is a link; GpuVM doesn't use it." }
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Couldn't set the permissions of $Path." }
}

# Hyper-V can't be trusted to grow a differencing disk: exactly the template's size.
function New-TemplateCloneConfig {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Template
    )
    $Config['guest'] = $Template['config']['guest']
    $Config['vm']['disk']['sizeGB'] = [int]$Template['sizeGB']
    $Config['vm']['disk']['type'] = 'Differencing'
    if ($Config.Contains('iso')) { $Config.Remove('iso') }
    $Config
}

function Get-BundledComponentStamp {
    $stamp = [ordered]@{}
    $package = try { Get-AgentPackage } catch { $null }
    if ($package) { $stamp['Program Files\GpuVM Agent\gpuvm-agent.exe'] = $package.Hash }
    foreach ($file in @(try { Get-SunshineForkFiles } catch { })) { $stamp["Program Files\Sunshine\$($file.Key)"] = $file.Hash }
    if ($package) {
        $winget = try { Get-WingetStampHash } catch { $null }
        if ($winget) { $stamp[$script:WingetStampKey] = $winget }
    }
    $stamp
}

function Get-GuestComponentStamp {
    param([Parameter(Mandatory)][string]$WindowsRoot, [Parameter(Mandatory)][string[]]$Keys)
    $stamp = [ordered]@{}
    foreach ($key in $Keys) {
        $path = Join-Path $WindowsRoot $key
        Assert-NoReparsePoint -Root $WindowsRoot -Path $path
        $stamp[$key] = if (Test-Path -LiteralPath $path -PathType Leaf) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
    }
    $stamp
}

function Get-TemplateComponentKeys {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Template, [Parameter(Mandatory)][System.Collections.IDictionary]$Bundled)
    $agent = [string]$Template['use'] -eq 'agent'
    $streams = $Template['streaming'] -is [System.Collections.IDictionary] -and [string]$Template['streaming']['provider'] -eq 'sunshine'
    @($Bundled.Keys | Where-Object { ($agent -and ($_ -like '*\gpuvm-agent.exe' -or $_ -eq $script:WingetStampKey)) -or ($streams -and $_ -like 'Program Files\Sunshine\*') })
}

function Test-GpuVMTemplateStale {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Template, [System.Collections.IDictionary]$Bundled)
    if (-not $Bundled) { $Bundled = Get-BundledComponentStamp }
    $keys = Get-TemplateComponentKeys -Template $Template -Bundled $Bundled
    if (-not $keys) { return $false }
    $have = $Template['components']
    if (-not ($have -is [System.Collections.IDictionary])) { return $true }
    foreach ($key in $keys) { if ([string]$have[$key] -ne [string]$Bundled[$key]) { return $true } }
    if (@($keys | Where-Object { $_ -like 'Program Files\Sunshine\*' }).Count -and -not $Template['gamepad']) { return $true }
    $false
}

function Get-TemplateUpdateMarker { param([Parameter(Mandatory)][System.Collections.IDictionary]$Template) Join-Path $Template['dir'] 'updating.json' }

function Test-TemplateUpdating {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Template)
    $path = Get-TemplateUpdateMarker -Template $Template
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $marker = try { Read-JsonFile $path } catch { $null }
    if (-not $marker) { return $false }
    # ConvertFrom-Json already turns the ISO text into a DateTime (a string would be parsed in the PC's culture).
    $value = $marker['startedAt']
    $started = if ($value -is [datetime]) { $value.ToUniversalTime() } else {
        try { [datetime]::Parse([string]$value, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { [datetime]::MinValue }
    }
    if (((Get-Date).ToUniversalTime() - $started).TotalMinutes -gt 60) { return $false }
    [bool](Get-Process -Id ([int]$marker['pid']) -ErrorAction SilentlyContinue)
}
