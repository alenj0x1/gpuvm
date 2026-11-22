function Get-ProfileDirectory { Get-RepoPath 'profiles' }

# Profiles the user creates in the app live with the data (the built-in folder is read-only when installed).
function Get-UserProfileDirectory { Get-DataPath 'user-profiles' }

function Find-ProfilePath {
    param([string]$Name, [string]$ProfileDirectory)
    if (Test-Path -LiteralPath $Name -PathType Leaf) { return (Resolve-Path -LiteralPath $Name).Path }
    $builtIn = Join-Path $ProfileDirectory "$Name.json"
    if ((Test-Path -LiteralPath $builtIn) -or $ProfileDirectory -ne (Get-ProfileDirectory)) { return $builtIn }
    Join-Path (Get-UserProfileDirectory) "$Name.json"
}

# Objects are deep-merged; lists are replaced entirely.
function Resolve-GpuVMProfile {
    param(
        [Parameter(Mandatory)][string]$Name,
        [System.Collections.IDictionary]$Override,
        [string]$ProfileDirectory = (Get-ProfileDirectory)
    )
    $chain = [System.Collections.Generic.List[string]]::new()
    $resolved = Resolve-ProfileChain -Name $Name -ProfileDirectory $ProfileDirectory -Chain $chain
    if ($Override) { $resolved = Merge-Hashtable -Base $resolved -Override $Override }
    $resolved.Remove('extends')
    $resolved['name'] = if (Test-Path -LiteralPath $Name -PathType Leaf) { [IO.Path]::GetFileNameWithoutExtension($Name) } else { $Name }
    $resolved['chain'] = @($chain)
    $resolved
}

function Resolve-ProfileChain {
    param(
        [string]$Name,
        [string]$ProfileDirectory,
        [System.Collections.Generic.List[string]]$Chain
    )
    $path = Find-ProfilePath -Name $Name -ProfileDirectory $ProfileDirectory
    if (-not (Test-Path -LiteralPath $path)) { throw "The profile '$Name' doesn't exist ($path)." }
    $key = [IO.Path]::GetFileNameWithoutExtension($path)
    if ($Chain.Contains($key)) { $cycle = @($Chain); [array]::Reverse($cycle); throw "Profiles inherit from each other in a circle: $($cycle -join ' → ') → $key" }
    $Chain.Insert(0, $key)

    $data = Read-JsonFile $path
    if ($data.Contains('extends') -and $data['extends']) {
        $parent = Resolve-ProfileChain -Name $data['extends'] -ProfileDirectory $ProfileDirectory -Chain $Chain
        return Merge-Hashtable -Base $parent -Override $data
    }
    $data
}

function Test-GpuVMProfileData {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [int]$HostLogicalProcessors = 0,
        [double]$HostMemoryGB = 0
    )
    $problems = [System.Collections.Generic.List[string]]::new()
    $vm = $Config['vm']
    if (-not $Config['backend']) { $problems.Add('"backend" is missing.') }
    if (-not $vm) { $problems.Add('The "vm" section is missing.'); return , $problems }

    $cpu = $vm['cpu']['count']
    if ($cpu -lt 2) { $problems.Add('vm.cpu.count must be at least 2 (Windows 11 requires it).') }
    if ($HostLogicalProcessors -and $cpu -ge $HostLogicalProcessors) {
        $problems.Add("vm.cpu.count ($cpu) must leave at least one thread to the host (it has $HostLogicalProcessors).")
    }
    $reserve = $vm['cpu']['reservePercent']
    if ($reserve -lt 0 -or $reserve -gt 100) { $problems.Add('vm.cpu.reservePercent goes from 0 to 100.') }
    $weight = $vm['cpu']['relativeWeight']
    if ($weight -lt 1 -or $weight -gt 10000) { $problems.Add('vm.cpu.relativeWeight goes from 1 to 10000.') }

    $mem = $vm['memoryGB']
    if ($mem -lt 4) { $problems.Add('vm.memoryGB must be at least 4 (Windows 11 requires it).') }
    if ($HostMemoryGB -and $mem -gt ($HostMemoryGB - 4)) {
        $problems.Add("vm.memoryGB ($mem) leaves less than 4 GB to the host (it has $([math]::Round($HostMemoryGB,1)) GB).")
    }

    if ($vm['disk']['type'] -notin 'Dynamic', 'Fixed', 'Differencing') { $problems.Add('vm.disk.type must be "Dynamic" or "Fixed".') }
    if ($vm['disk']['sizeGB'] -lt 64) { $problems.Add('vm.disk.sizeGB must be at least 64.') }

    $alloc = $Config['gpu']['allocationPercent']
    if ($alloc -lt 1 -or $alloc -gt 100) { $problems.Add('gpu.allocationPercent goes from 1 to 100.') }

    $streaming = $Config['streaming']
    if ($streaming) {
        if ($streaming['provider'] -notin 'sunshine', 'none') { $problems.Add('streaming.provider must be "sunshine" or "none".') }
        if ($streaming['audio'] -and $streaming['audio'] -notin 'usb', 'vbcable', 'none') { $problems.Add('streaming.audio must be "usb" or "none".') }
        $client = $streaming['client']
        if ($client -and $client['resolution'] -and $client['resolution'] -notmatch '^\d{3,5}x\d{3,5}$') {
            $problems.Add('streaming.client.resolution must look like 1920x1080.')
        }
        if ($client -and $client['fps'] -and ($client['fps'] -lt 10 -or $client['fps'] -gt 480)) { $problems.Add('streaming.client.fps goes from 10 to 480.') }
        if ($client -and $client['codec'] -and $client['codec'] -notin 'auto', 'H.264', 'HEVC', 'AV1') { $problems.Add('streaming.client.codec must be auto, H.264, HEVC or AV1.') }
        if ($client -and $client.Contains('displayMode') -and $client['displayMode'] -and $client['displayMode'] -notin 'fullscreen', 'windowed', 'borderless') {
            $problems.Add('streaming.client.displayMode must be fullscreen, windowed or borderless.')
        }
        if ($streaming['disableHyperVVideo'] -and -not $streaming['virtualDisplay']) {
            $problems.Add('streaming.disableHyperVVideo needs virtualDisplay; without a virtual display the VM would have no screen.')
        }
    }

    $guest = $Config['guest']
    if ($guest -and $guest.Contains('apps') -and $guest['apps']) {
        $known = @((Get-AppCatalog).Keys)
        foreach ($app in @($guest['apps'])) {
            if ($app -notin $known) { $problems.Add("guest.apps: the app '$app' isn't in the catalog.") }
        }
    }
    if ($guest -and $guest.Contains('cleanup') -and $guest['cleanup'] -notin 'none', 'privacy', 'apps', 'minimal') {
        $problems.Add('guest.cleanup must be none, privacy, apps or minimal.')
    }
    if ($Config.Contains('iso') -and $Config['iso'] -and [IO.Path]::GetExtension($Config['iso']) -ne '.iso') {
        $problems.Add('iso must be the path to an .iso file.')
    }

    , $problems
}
