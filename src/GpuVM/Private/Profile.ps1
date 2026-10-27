function Get-ProfileDirectory { Get-RepoPath 'profiles' }

# Loads a profile by name or path, resolves the "extends" chain and applies an optional override.
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
    $path = if (Test-Path -LiteralPath $Name -PathType Leaf) { (Resolve-Path -LiteralPath $Name).Path } else { Join-Path $ProfileDirectory "$Name.json" }
    if (-not (Test-Path -LiteralPath $path)) { throw "No existe el perfil '$Name' ($path)." }
    $key = [IO.Path]::GetFileNameWithoutExtension($path)
    if ($Chain.Contains($key)) { $cycle = @($Chain); [array]::Reverse($cycle); throw "Herencia circular de perfiles: $($cycle -join ' → ') → $key" }
    $Chain.Insert(0, $key)

    $data = Read-JsonFile $path
    if ($data.Contains('extends') -and $data['extends']) {
        $parent = Resolve-ProfileChain -Name $data['extends'] -ProfileDirectory $ProfileDirectory -Chain $Chain
        return Merge-Hashtable -Base $parent -Override $data
    }
    $data
}

# Returns the list of profile problems (empty if valid). Checks against the hardware if provided.
function Test-GpuVMProfileData {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [int]$HostLogicalProcessors = 0,
        [double]$HostMemoryGB = 0
    )
    $problems = [System.Collections.Generic.List[string]]::new()
    $vm = $Config['vm']
    if (-not $Config['backend']) { $problems.Add('Falta "backend".') }
    if (-not $vm) { $problems.Add('Falta la sección "vm".'); return , $problems }

    $cpu = $vm['cpu']['count']
    if ($cpu -lt 2) { $problems.Add('vm.cpu.count debe ser al menos 2 (Windows 11 lo exige).') }
    if ($HostLogicalProcessors -and $cpu -ge $HostLogicalProcessors) {
        $problems.Add("vm.cpu.count ($cpu) debe dejar al menos un hilo al host (tiene $HostLogicalProcessors).")
    }
    $reserve = $vm['cpu']['reservePercent']
    if ($reserve -lt 0 -or $reserve -gt 100) { $problems.Add('vm.cpu.reservePercent va de 0 a 100.') }
    $weight = $vm['cpu']['relativeWeight']
    if ($weight -lt 1 -or $weight -gt 10000) { $problems.Add('vm.cpu.relativeWeight va de 1 a 10000.') }

    $mem = $vm['memoryGB']
    if ($mem -lt 4) { $problems.Add('vm.memoryGB debe ser al menos 4 (Windows 11 lo exige).') }
    if ($HostMemoryGB -and $mem -gt ($HostMemoryGB - 4)) {
        $problems.Add("vm.memoryGB ($mem) deja menos de 4 GB al host (tiene $([math]::Round($HostMemoryGB,1)) GB).")
    }

    if ($vm['disk']['type'] -notin 'Dynamic', 'Fixed') { $problems.Add('vm.disk.type debe ser "Dynamic" o "Fixed".') }
    if ($vm['disk']['sizeGB'] -lt 64) { $problems.Add('vm.disk.sizeGB debe ser al menos 64.') }

    $alloc = $Config['gpu']['allocationPercent']
    if ($alloc -lt 1 -or $alloc -gt 100) { $problems.Add('gpu.allocationPercent va de 1 a 100.') }

    $streaming = $Config['streaming']
    if ($streaming) {
        if ($streaming['provider'] -notin 'sunshine', 'none') { $problems.Add('streaming.provider debe ser "sunshine" o "none".') }
        if ($streaming['audio'] -and $streaming['audio'] -notin 'vbcable', 'none') { $problems.Add('streaming.audio debe ser "vbcable" o "none".') }
        $client = $streaming['client']
        if ($client -and $client['resolution'] -and $client['resolution'] -notmatch '^\d{3,5}x\d{3,5}$') {
            $problems.Add('streaming.client.resolution debe tener la forma 1920x1080.')
        }
        if ($client -and $client['fps'] -and ($client['fps'] -lt 10 -or $client['fps'] -gt 480)) { $problems.Add('streaming.client.fps va de 10 a 480.') }
        if ($client -and $client['codec'] -and $client['codec'] -notin 'auto', 'H.264', 'HEVC', 'AV1') { $problems.Add('streaming.client.codec debe ser auto, H.264, HEVC o AV1.') }
        if ($streaming['disableHyperVVideo'] -and -not $streaming['virtualDisplay']) {
            $problems.Add('streaming.disableHyperVVideo requiere virtualDisplay; sin pantalla virtual la VM se quedaría sin pantalla.')
        }
    }

    , $problems
}
