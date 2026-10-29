# A backend is a way of giving the GPU to the VM (GPU-P on Hyper-V today; VFIO on KVM later).
# Each one implements these operations as scriptblocks; public commands only talk to this interface.
$script:BackendOperations = @(
    'Test'        # param($Config) → check objects (Name, Status, Detail)
    'New'         # param($Context) → creates the VM from scratch
    'Clone'       # param($Context) → creates the VM on top of a template's disk (Context.Template)
    'Apply'       # param($Name, $Config) → applies CPU, memory, GPU, etc. to a stopped VM
    'SyncDriver'  # param($Name, $State) → copies the host driver again; returns the copied version
    'Remove'      # param($Name, $State, $DeleteDisk)
)

function Register-GpuVMBackend {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][hashtable]$Operations
    )
    $missing = $script:BackendOperations | Where-Object { -not $Operations.ContainsKey($_) }
    if ($missing) { throw "El backend '$Name' no implementa: $($missing -join ', ')" }
    $script:Backends[$Name] = [pscustomobject]@{
        Name        = $Name
        Description = $Description
        Operations  = $Operations
    }
}

function Get-GpuVMBackend {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:Backends.ContainsKey($Name)) {
        throw "Backend desconocido '$Name'. Disponibles: $($script:Backends.Keys -join ', ')"
    }
    $script:Backends[$Name]
}

function Invoke-GpuVMBackend {
    param(
        [Parameter(Mandatory)][string]$Backend,
        [Parameter(Mandatory)][ValidateScript({ $_ -in $script:BackendOperations })][string]$Operation,
        [object[]]$Arguments = @()
    )
    $impl = Get-GpuVMBackend $Backend
    & $impl.Operations[$Operation] @Arguments
}

function New-CheckResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Ok', 'Warn', 'Fail')][string]$Status,
        [string]$Detail = ''
    )
    [pscustomobject]@{ PSTypeName = 'GpuVM.Check'; Name = $Name; Status = $Status; Detail = $Detail }
}
