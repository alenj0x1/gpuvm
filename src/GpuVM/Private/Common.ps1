function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-IsAdmin)) {
        throw 'Este comando necesita PowerShell 7 abierto como administrador.'
    }
}

# A GPU-P VM has fixed memory: it must be free on the host at power-on.
function Assert-FreeMemory {
    param(
        [Parameter(Mandatory)][double]$RequiredGB,
        [double]$ExtraFreeGB = 0
    )
    $freeGB = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB + $ExtraFreeGB
    if ($freeGB -lt $RequiredGB + 0.3) {
        $suggest = [math]::Max(4, [math]::Floor($freeGB - 0.5))
        throw ("La VM necesita {0} GB libres y hay {1:N1} GB. Cierra programas o baja su memoria a {2} GB en Opciones." -f $RequiredGB, $freeGB, $suggest)
    }
}

function Assert-VMCanStart {
    param([Parameter(Mandatory)][string]$Name)
    $vm = Get-VM -Name $Name
    if ($vm.State -eq 'Off') { Assert-FreeMemory -RequiredGB ($vm.MemoryStartup / 1GB) }
}

$script:AdminSids = @('S-1-5-32-544', 'S-1-5-18')
# WriteData, AppendData, WriteEA, DeleteChild, WriteAttributes, Delete, WRITE_DAC, WRITE_OWNER, GENERIC_ALL, GENERIC_WRITE.
$script:WriteRightsMask = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000

# True when the ACL is owned by Administrators/SYSTEM, does not inherit, and only they can write.
function Test-GpuVMRootAcl {
    param([Parameter(Mandatory)][System.Security.AccessControl.FileSystemSecurity]$Acl)
    $owner = $Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin $script:AdminSids -or -not $Acl.AreAccessRulesProtected) { return $false }
    foreach ($rule in $Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow' -or $rule.IdentityReference.Value -in $script:AdminSids) { continue }
        if (([int64]$rule.FileSystemRights -band $script:WriteRightsMask) -ne 0) { return $false }
    }
    $true
}

# C:\GpuVM inherits the "Authenticated Users: Modify" permission from C:\ (and ProgramData lets users create folders).
# Since the app runs as administrator and reads/deletes what is in there, only Administrators and SYSTEM can write;
# Hyper-V VMs (S-1-5-83-0) only read: Hyper-V grants each VM's own SID access to its disk and configuration files.
# A folder a user created beforehand (and therefore owns) is taken back, not trusted.
function Initialize-GpuVMRoot {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "$Path es un enlace a otra carpeta; GpuVM no la usará. Bórralo y vuelve a intentarlo."
    }
    if (Test-GpuVMRootAcl -Acl (Get-Acl -LiteralPath $Path)) { return }
    if ((Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $script:AdminSids) {
        & takeown.exe /F $Path /A | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "No se pudo recuperar la propiedad de $Path para Administradores." }
    }
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-83-0:(OI)(CI)RX' /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "No se pudieron restringir los permisos de $Path." }
    # Explicit grants other than the three above (e.g. a user's own) are removed.
    $acl = Get-Acl -LiteralPath $Path
    $extra = @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) |
        Where-Object { $_.IdentityReference.Value -notin ($script:AdminSids + 'S-1-5-83-0') })
    if ($extra.Count) {
        foreach ($rule in $extra) { $acl.RemoveAccessRuleSpecific($rule) }
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
    if (-not (Test-GpuVMRootAcl -Acl (Get-Acl -LiteralPath $Path))) { throw "No se pudieron restringir los permisos de $Path." }
}

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    # The desktop app installs a sink to show progress on the button that started the job.
    # Get-Variable: under StrictMode, reading the variable when it does not exist (CLI) would throw.
    $sink = Get-Variable -Name GpuVMProgressSink -Scope Global -ValueOnly -ErrorAction Ignore
    if ($sink) { & $sink $Message; return }
    Write-Host "› $Message" -ForegroundColor Cyan
}

function Get-DataPath {
    param([Parameter(Mandatory)][string]$Relative)
    if ($script:DataRoot -ne $script:RepoRoot -and (Test-IsAdmin)) { Initialize-GpuVMRoot -Path $script:DataRoot }
    Join-Path $script:DataRoot $Relative
}

function Get-RepoPath {
    param([Parameter(Mandatory)][string]$Relative)
    Join-Path $script:RepoRoot $Relative
}

# Deep merge: values from $Override win; hashtables are merged recursively.
function Merge-Hashtable {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Base,
        [System.Collections.IDictionary]$Override
    )
    $result = [ordered]@{}
    foreach ($key in $Base.Keys) { $result[$key] = Copy-Value $Base[$key] }
    if ($Override) {
        foreach ($key in $Override.Keys) {
            $incoming = $Override[$key]
            if ($result.Contains($key) -and $result[$key] -is [System.Collections.IDictionary] -and $incoming -is [System.Collections.IDictionary]) {
                $result[$key] = Merge-Hashtable -Base $result[$key] -Override $incoming
            }
            else {
                $result[$key] = Copy-Value $incoming
            }
        }
    }
    $result
}

function Copy-Value {
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) { return Merge-Hashtable -Base $Value }
    if ($Value -is [System.Collections.IList] -and $Value -isnot [string]) { return , @($Value | ForEach-Object { Copy-Value $_ }) }
    $Value
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Data
    )
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Data | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function ConvertTo-Slug {
    param([Parameter(Mandatory)][string]$Text)
    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $ascii = -join ($normalized.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
    ($ascii.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
}

function Get-GpuVMStatePath {
    param(
        [Parameter(Mandatory)][string]$VMRoot,
        [Parameter(Mandatory)][string]$Name
    )
    Join-Path (Join-Path $VMRoot $Name) 'gpuvm.json'
}

# Finds the state file of an existing VM from the path Hyper-V has registered.
function Get-GpuVMState {
    param([Parameter(Mandatory)][string]$Name)
    $vm = Get-VM -Name $Name -ErrorAction Stop
    $candidates = @(
        (Join-Path $vm.Path 'gpuvm.json')
        (Join-Path (Join-Path $vm.Path $Name) 'gpuvm.json')
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) {
            $state = Read-JsonFile $path
            $state['statePath'] = $path
            return $state
        }
    }
    throw "La VM '$Name' no fue creada con GpuVM (no se encontró gpuvm.json)."
}

function Save-GpuVMState {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    $path = $State['statePath']
    $copy = Merge-Hashtable -Base $State
    $copy.Remove('statePath')
    Write-JsonFile -Path $path -Data $copy
}
