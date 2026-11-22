# The disposable mark is only set at creation: an existing machine can never become disposable.

$script:DisposableGraceMinutes = 30
$script:DisposableReserveGB = 20

function Test-GpuVMDisposableByName {
    param([Parameter(Mandatory)][string]$Name)
    $state = try { Get-GpuVMState -Name $Name } catch { $null }
    Test-GpuVMDisposable -State $state
}

function Test-GpuVMDisposable {
    param([System.Collections.IDictionary]$State)
    [bool]($State -and $State.Contains('disposable') -and $State['disposable'] -is [System.Collections.IDictionary])
}

function Set-GpuVMDisposableStarted {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    if (-not (Test-GpuVMDisposable -State $State) -or $State['disposable']['startedAt']) { return }
    $State['disposable']['startedAt'] = (Get-Date).ToString('o')
    Save-GpuVMState $State
}

function Test-GpuVMDisposableDone {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State, [string]$VMState)
    if (-not (Test-GpuVMDisposable -State $State)) { return $false }
    if ($VMState -and $VMState -ne 'Off') { return $false }
    $cycling = $State['disposable']['cyclingUntil']
    $until = [datetime]::MinValue
    if ($cycling -is [datetime]) { $until = $cycling.ToUniversalTime() }
    elseif ($cycling) { [void][datetime]::TryParse([string]$cycling, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$until); $until = $until.ToUniversalTime() }
    if ($until -gt (Get-Date).ToUniversalTime()) { return $false }
    if ($State['disposable']['startedAt']) { return $true }
    # ConvertFrom-Json already returns a DateTime ([string] of it is culture-dependent). An unreadable date keeps the machine.
    $value = $State['disposable']['createdAt']
    $created = [datetime]::MinValue
    if ($value -is [datetime]) { $created = $value }
    elseif (-not [datetime]::TryParse([string]$value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$created)) { return $false }
    ((Get-Date) - $created).TotalMinutes -ge $script:DisposableGraceMinutes
}

function Assert-GpuVMNotDisposable {
    param([System.Collections.IDictionary]$State, [Parameter(Mandatory)][string]$Action)
    if (Test-GpuVMDisposable -State $State) { throw "A disposable machine can't $Action. Keep it first to do that." }
}
