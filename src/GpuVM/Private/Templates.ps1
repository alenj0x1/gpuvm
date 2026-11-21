# Templates: a VM's Windows saved as a read-only base disk. A VM created from a template gets a differencing
# disk on top of it (only what changes is written), so it is ready in seconds and takes a few GB.
# Templates live in <root>\.templates\<name>\ (a dot can't start a VM name, so they never clash with VM folders).

function Get-TemplateRoot { Join-Path (Get-GpuVMDefaultRoot) '.templates' }

function Get-TemplateDirectory {
    param([Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name)
    Join-Path (Get-TemplateRoot) $Name
}

# The template's metadata (template.json) with the paths taken from where it really is, never from the file.
function Read-GpuVMTemplate {
    param([Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name)
    $dir = Get-TemplateDirectory -Name $Name
    $metaPath = Join-Path $dir 'template.json'
    if (-not (Test-Path -LiteralPath $metaPath)) { throw "The template '$Name' doesn't exist." }
    $meta = Read-JsonFile $metaPath
    $meta['name'] = $Name
    $meta['dir'] = $dir
    # A template is its base disk plus the layers Update-GpuVMTemplate added on top (each a read-only differencing
    # disk of the one before). New copies sit on the last one; older copies keep the layer they were made on.
    $layers = @(if ($meta['layers']) { $meta['layers'] | ForEach-Object { [string]$_ } } else { "$Name.vhdx" })
    foreach ($layer in $layers) {
        if ($layer -notmatch '^[\w.-]{1,80}\.vhdx$' -or $layer -match '\.\.') { throw "The template '$Name' names a disk GpuVM doesn't use ($layer)." }
    }
    $meta['layerPaths'] = @($layers | ForEach-Object { Join-Path $dir $_ })
    $meta['vhdPath'] = $meta['layerPaths'][-1]
    foreach ($path in $meta['layerPaths']) { if (-not (Test-Path -LiteralPath $path)) { throw "The template '$Name' is missing its disk ($(Split-Path $path -Leaf))." } }
    $meta
}

# The VMs whose disk sits on top of a template (by the disk's real parent, not by what a state file says). Several
# paths: the template's layers (a copy made before an update sits on an inner one).
function Get-TemplateChildVM {
    param([Parameter(Mandatory)][string[]]$VhdPath)
    $full = @($VhdPath | ForEach-Object { [IO.Path]::GetFullPath($_) })
    # Every disk Hyper-V knows (wherever its VM lives) plus the kept disks in GpuVM's folder, following each
    # disk's chain of parents: a copy of a copy also depends on the template.
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

# A copy of a template must not look like the VM it came from to Moonlight: Sunshine gets a new identity and
# certificate (it creates them again when they are missing) and forgets the paired devices. Its web credentials
# stay, so GpuVM keeps using the ones saved with the template. Runs on the clone's disk before it ever boots.
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
    # Never the template's agent secret: each copy gets its own from Install-GpuVMAgent (an older template could
    # still carry one).
    Remove-GuestAgentSecret -WindowsRoot $WindowsRoot
}

# Templates and shared disks don't inherit the root's read access for the Virtual Machines group: only
# Administrators and SYSTEM, and Hyper-V grants each VM access to the disks it attaches (a template is reached as
# the parent of a VM's disk). So one VM's worker process can't read another's template or shared disk.
function Protect-GpuVMSharedFolder {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Path is a link; GpuVM doesn't use it." }
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Couldn't set the permissions of $Path." }
}

# A copy's settings: processors, memory, GPU and Moonlight from the profile; what lives inside Windows (user, apps,
# cleanup level) from the template. Its disk is a differencing disk of exactly the template's size (Hyper-V can't be
# trusted to grow one), and there is no ISO.
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

# ---------------------------------------------------------------- keeping agent templates current (layers)

# What this GpuVM build puts into its machines, by content: GpuVM's Sunshine fork, the agent's exe and, with the
# agent, winget's release (only the parts this build carries). Keys are the files' places inside Windows.
function Get-BundledComponentStamp {
    $stamp = [ordered]@{}
    $package = try { Get-AgentPackage } catch { $null }
    if ($package) { $stamp['Program Files\GpuVM Agent\gpuvm-agent.exe'] = $package.Hash }
    foreach ($file in @(try { Get-SunshineForkFiles } catch { })) { $stamp["Program Files\Sunshine\$($file.Key)"] = $file.Hash }
    # With the agent, winget for its user (lab 060): the stamp file Install-GuestWinget writes, by its text's hash.
    if ($package) {
        $winget = try { Get-WingetStampHash } catch { $null }
        if ($winget) { $stamp[$script:WingetStampKey] = $winget }
    }
    $stamp
}

# The same files' hashes inside a mounted Windows (a template's disk): $null for one that isn't there.
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

# What a template must carry from this build: GpuVM's Sunshine when its machines stream, and the agent too when it
# makes agent machines. A subset of the bundled stamp.
function Get-TemplateComponentKeys {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Template, [Parameter(Mandatory)][System.Collections.IDictionary]$Bundled)
    $agent = [string]$Template['use'] -eq 'agent'
    $streams = $Template['streaming'] -is [System.Collections.IDictionary] -and [string]$Template['streaming']['provider'] -eq 'sunshine'
    @($Bundled.Keys | Where-Object { ($agent -and ($_ -like '*\gpuvm-agent.exe' -or $_ -eq $script:WingetStampKey)) -or ($streams -and $_ -like 'Program Files\Sunshine\*') })
}

# A template whose Sunshine (or agent, for an agent template) differs from this build's: every copy would install
# them again (for an agent copy a full install and a power cycle, ~5 min instead of under one; lab 053 part 6). A
# template from before stamps is stale.
function Test-GpuVMTemplateStale {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Template, [System.Collections.IDictionary]$Bundled)
    if (-not $Bundled) { $Bundled = Get-BundledComponentStamp }
    $keys = Get-TemplateComponentKeys -Template $Template -Bundled $Bundled
    if (-not $keys) { return $false }
    $have = $Template['components']
    if (-not ($have -is [System.Collections.IDictionary])) { return $true }
    foreach ($key in $keys) { if ([string]$have[$key] -ne [string]$Bundled[$key]) { return $true } }
    # A template that streams also carries the controllers' driver, so its copies don't install it on their first open.
    if (@($keys | Where-Object { $_ -like 'Program Files\Sunshine\*' }).Count -and -not $Template['gamepad']) { return $true }
    $false
}

# The update marker: <template>\updating.json with the process and when it started. One older than an hour, or whose
# process is gone, is left over from a run that died.
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
