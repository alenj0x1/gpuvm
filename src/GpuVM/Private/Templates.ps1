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
    if (-not (Test-Path -LiteralPath $metaPath)) { throw "No existe la plantilla '$Name'." }
    $meta = Read-JsonFile $metaPath
    $meta['name'] = $Name
    $meta['dir'] = $dir
    $meta['vhdPath'] = Join-Path $dir "$Name.vhdx"
    if (-not (Test-Path -LiteralPath $meta['vhdPath'])) { throw "Falta el disco de la plantilla '$Name'." }
    $meta
}

# The VMs whose disk sits on top of a template (by the disk's real parent, not by what a state file says).
function Get-TemplateChildVM {
    param([Parameter(Mandatory)][string]$VhdPath)
    $full = [IO.Path]::GetFullPath($VhdPath)
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
            if ([IO.Path]::GetFullPath($vhd.ParentPath) -eq $full) { $disks[$path]; break }
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
}

# Templates and shared disks don't inherit the root's read access for the Virtual Machines group: only
# Administrators and SYSTEM, and Hyper-V grants each VM access to the disks it attaches (a template is reached as
# the parent of a VM's disk). So one VM's worker process can't read another's template or shared disk.
function Protect-GpuVMSharedFolder {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Path es un enlace; GpuVM no lo usa." }
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "No se pudieron ajustar los permisos de $Path." }
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
