function Save-GpuVMProfile {
    <#
    .SYNOPSIS
    Creates or updates a user profile: the values to start from when creating a machine (processor, memory,
    GPU, disk, ISO, apps and how Moonlight opens it). It extends a built-in profile; built-in ones cannot be changed.
    .EXAMPLE
    Save-GpuVMProfile -Name juegos -Settings @{ cpu = 8; memoryGB = 8; diskGB = 250; apps = @('steam') }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name,
        [string]$Description = '',
        [ValidatePattern('^[\w-]{1,40}$')][string]$Extends = 'max-performance',
        [Parameter(Mandatory)][hashtable]$Settings,
        # When renaming, the profile saved under this name is replaced.
        [ValidatePattern('^[\w-]{1,40}$')][string]$Previous
    )
    if (Test-Path -LiteralPath (Join-Path (Get-ProfileDirectory) "$Name.json")) { throw "'$Name' es un perfil incluido; usa otro nombre." }
    if ($Extends -eq $Name) { throw 'Un perfil no puede extenderse a sí mismo.' }
    if ($Description.Length -gt 200) { throw 'La descripción es demasiado larga.' }

    $s = $Settings
    $vm = [ordered]@{}
    if ($s.ContainsKey('cpu')) { $vm['cpu'] = [ordered]@{ count = [int]$s['cpu'] } }
    if ($s.ContainsKey('memoryGB')) { $vm['memoryGB'] = [int]$s['memoryGB'] }
    $disk = [ordered]@{}
    if ($s.ContainsKey('diskGB')) { $disk['sizeGB'] = [int]$s['diskGB'] }
    if ($s.ContainsKey('diskType')) { $disk['type'] = [string]$s['diskType'] }
    if ($disk.Count) { $vm['disk'] = $disk }
    $client = [ordered]@{}
    if ($s['resolution']) { $client['resolution'] = [string]$s['resolution'] }
    if ($s['fps']) { $client['fps'] = [int]$s['fps'] }
    if ($s['displayMode']) { $client['displayMode'] = [string]$s['displayMode'] }

    $data = [ordered]@{ extends = $Extends; description = $Description }
    if ($vm.Count) { $data['vm'] = $vm }
    if ($s.ContainsKey('gpuPercent')) { $data['gpu'] = [ordered]@{ allocationPercent = [int]$s['gpuPercent'] } }
    if ($client.Count) { $data['streaming'] = [ordered]@{ client = $client } }
    $guest = [ordered]@{}
    if ($s.ContainsKey('apps')) { $guest['apps'] = @($s['apps'] | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
    if ($s['cleanup']) { $guest['cleanup'] = [string]$s['cleanup'] }
    if ($guest.Count) { $data['guest'] = $guest }
    if ($s['iso']) { $data['iso'] = [IO.Path]::GetFullPath([string]$s['iso']) }

    # Validate the result as it will be used, against this computer's hardware.
    $config = Merge-Hashtable -Base (Resolve-GpuVMProfile -Name $Extends) -Override $data
    $cs = Get-CimInstance Win32_ComputerSystem
    $logical = [int](Get-CimInstance Win32_Processor | Select-Object -First 1).NumberOfLogicalProcessors
    $problems = Test-GpuVMProfileData -Config $config -HostLogicalProcessors $logical -HostMemoryGB ($cs.TotalPhysicalMemory / 1GB)
    if ($problems.Count) { throw ($problems -join ' ') }

    $dir = Get-UserProfileDirectory
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir "$Name.json"
    $renamed = $Previous -and $Previous -ne $Name
    if ($renamed) {
        if (Test-Path -LiteralPath $path) { throw "Ya hay un perfil llamado '$Name'." }
        $children = @(Get-ChildItem $dir -Filter *.json | Where-Object { (Read-JsonFile $_.FullName)['extends'] -eq $Previous })
        if ($children) { throw "No se puede renombrar: lo usan otros perfiles ($(($children.BaseName) -join ', '))." }
    }
    # The new file is written first, so a failed write never loses the profile.
    Write-JsonFile -Path $path -Data $data
    if ($renamed) { Remove-Item -LiteralPath (Join-Path $dir "$Previous.json") -ErrorAction SilentlyContinue }
    Get-GpuVMProfile | Where-Object Name -eq $Name
}
