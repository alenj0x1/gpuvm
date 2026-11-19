# Disposable machines: a copy of a template (a differencing disk, ready in seconds) that is deleted with its disk
# once it has been on and is off again. The mark lives in its gpuvm.json, which only administrators can write (the
# VMs' folder is restricted), and it can only be set when the VM is made: an existing machine can never be turned
# into a disposable one, so the cleanup never deletes a machine someone meant to keep.

# Grace period for a disposable machine that never started (creation interrupted, not enough memory): after it,
# the cleanup deletes it too.
$script:DisposableGraceMinutes = 30
# What a disposable machine reserves on the drive (the others reserve their disk's full size). If the drive gets
# down to the host's margin while one runs, it is shut down cleanly and then deleted like any used disposable machine.
$script:DisposableReserveGB = 20

# Whether the VM that owns a disk is a disposable machine (for the disk-room count), read from its gpuvm.json.
function Test-GpuVMDisposableByName {
    param([Parameter(Mandatory)][string]$Name)
    $state = try { Get-GpuVMState -Name $Name } catch { $null }
    Test-GpuVMDisposable -State $state
}

function Test-GpuVMDisposable {
    param([System.Collections.IDictionary]$State)
    [bool]($State -and $State.Contains('disposable') -and $State['disposable'] -is [System.Collections.IDictionary])
}

# Remembered when it starts: from then on, being off means it was used and closed.
function Set-GpuVMDisposableStarted {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    if (-not (Test-GpuVMDisposable -State $State) -or $State['disposable']['startedAt']) { return }
    $State['disposable']['startedAt'] = (Get-Date).ToString('o')
    Save-GpuVMState $State
}

# Whether the cleanup deletes this disposable machine now.
function Test-GpuVMDisposableDone {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State, [string]$VMState)
    if (-not (Test-GpuVMDisposable -State $State)) { return $false }
    if ($VMState -and $VMState -ne 'Off') { return $false }
    # Turned off only to be turned on again (Restart-GpuVMCold): not done.
    $cycling = $State['disposable']['cyclingUntil']
    $until = [datetime]::MinValue
    if ($cycling -is [datetime]) { $until = $cycling.ToUniversalTime() }
    elseif ($cycling) { [void][datetime]::TryParse([string]$cycling, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$until); $until = $until.ToUniversalTime() }
    if ($until -gt (Get-Date).ToUniversalTime()) { return $false }
    if ($State['disposable']['startedAt']) { return $true }
    # ConvertFrom-Json already turns the ISO text into a DateTime; [string] of that follows the system's culture and
    # didn't parse back on en-GB, so a just-created machine read as "used" and was deleted. A date that can't be read
    # keeps the machine: deleting is the step that can't be undone.
    $value = $State['disposable']['createdAt']
    $created = [datetime]::MinValue
    if ($value -is [datetime]) { $created = $value }
    elseif (-not [datetime]::TryParse([string]$value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$created)) { return $false }
    ((Get-Date) - $created).TotalMinutes -ge $script:DisposableGraceMinutes
}

# Taking points, going back or exporting needs the machine off; a used disposable machine that is off gets deleted by
# the next sweep, so these refuse disposable machines (Set-GpuVMDisposable -Keep makes one a normal machine first).
# -Action completes "A disposable machine can't …": 'be exported', 'keep restore points', 'go back to a restore point',
# 'change its restore points', 'be saved as a template'.
function Assert-GpuVMNotDisposable {
    param([System.Collections.IDictionary]$State, [Parameter(Mandatory)][string]$Action)
    if (Test-GpuVMDisposable -State $State) { throw "A disposable machine can't $Action. Keep it first to do that." }
}
