$script:BackendOperations = @(
    'Test'
    'New'
    'Clone'
    'Apply'
    'SyncDriver'
    'Rename'
    'Remove'
)

function Register-GpuVMBackend {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][hashtable]$Operations
    )
    $missing = $script:BackendOperations | Where-Object { -not $Operations.ContainsKey($_) }
    if ($missing) { throw "The backend '$Name' doesn't implement: $($missing -join ', ')" }
    $script:Backends[$Name] = [pscustomobject]@{
        Name        = $Name
        Description = $Description
        Operations  = $Operations
    }
}

function Get-GpuVMBackend {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:Backends.ContainsKey($Name)) {
        throw "Unknown backend '$Name'. Available: $($script:Backends.Keys -join ', ')"
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
