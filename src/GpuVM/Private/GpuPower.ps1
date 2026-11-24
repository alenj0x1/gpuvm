# One GPU-P machine changes power at a time: overlapping transitions on one GPU hung a guest into a 0x9F blue screen.
# Start-VM, Stop-VM and Restart-VM below shadow Hyper-V's own inside this module, so every caller takes the mutex.

$script:GpuPowerMutexName = 'Global\GpuVM.GpuPower'
$script:GpuPowerWaitSec = 300
$script:GpuPowerUpSec = 90

function Write-PowerLog {
    param([Parameter(Mandatory)][string]$Message)
    try {
        $dir = Join-Path $env:ProgramData 'GpuVM'
        if (Test-Path -LiteralPath $dir) { Add-Content -LiteralPath (Join-Path $dir 'power.log') -Value "$((Get-Date).ToString('o')) $Message" -ErrorAction Stop }
    }
    catch { }
}

# SYSTEM and Administrators only. $null when it can't be had: the transition then goes on unserialized.
function Get-GpuPowerMutex {
    try { return [Threading.Mutex]::OpenExisting($script:GpuPowerMutexName) } catch { }
    try {
        $security = [Security.AccessControl.MutexSecurity]::new()
        foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
            $who = [Security.Principal.SecurityIdentifier]::new($sid)
            $security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new($who, [Security.AccessControl.MutexRights]::FullControl, 'Allow'))
        }
        $created = $false
        return [Threading.MutexAcl]::Create($false, $script:GpuPowerMutexName, [ref]$created, $security)
    }
    catch {
        try { return [Threading.Mutex]::OpenExisting($script:GpuPowerMutexName) } catch { return $null }
    }
}

function Test-GpuPartitioned {
    param([Parameter(Mandatory)][string]$Name)
    [bool](Get-VMGpuPartitionAdapter -VMName $Name -ErrorAction SilentlyContinue)
}

function Invoke-GpuPowerTransition {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Do, [switch]$UntilUp, [int]$WaitSec = $script:GpuPowerWaitSec)
    if (-not (Test-GpuPartitioned -Name $Name)) { return & $Do }
    $mutex = Get-GpuPowerMutex
    $held = $false
    if ($mutex) {
        $w = [Diagnostics.Stopwatch]::StartNew()
        try { $held = $mutex.WaitOne([TimeSpan]::FromSeconds($WaitSec)) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if ($w.Elapsed.TotalSeconds -ge 5) { Write-PowerLog "$Name waited $([int]$w.Elapsed.TotalSeconds) s for another GPU machine's power change" }
        if (-not $held) {
            Write-PowerLog "$Name went ahead after waiting $WaitSec s for another GPU machine's power change"
            Write-Warning "Another machine on the GPU kept changing power for $WaitSec s; '$Name' goes ahead anyway."
        }
    }
    try {
        & $Do
        if ($UntilUp) {
            $deadline = (Get-Date).AddSeconds($script:GpuPowerUpSec)
            while ((Get-Date) -lt $deadline -and (Get-VM -Name $Name).State -eq 'Running' -and -not (Test-GuestHeartbeat -Name $Name)) { Start-Sleep -Seconds 1 }
        }
    }
    finally {
        if ($held) { try { $mutex.ReleaseMutex() } catch { } }
        if ($mutex) { $mutex.Dispose() }
    }
}

function Start-VM {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    # HCS machines share the GPU the same way: their power changes wait their turn too.
    if (Test-GpuVMHcsMachine -Name $Name) { return Invoke-GpuPowerTransition -Name $Name -UntilUp -Do { Start-HcsMachine -Name $Name } }
    # An agent machine never starts with an adapter on a switch where it isn't isolated (Network.ps1).
    Assert-AgentMachineSwitch -Name $Name
    Invoke-GpuPowerTransition -Name $Name -UntilUp -Do { Invoke-WithGpuChoice -Name $Name -Do { Hyper-V\Start-VM -Name $Name } }
}

function Stop-VM {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [switch]$Force, [switch]$TurnOff, [switch]$AsJob)
    if (Test-GpuVMHcsMachine -Name $Name) { return Invoke-GpuPowerTransition -Name $Name -Do { Stop-HcsMachine -Name $Name -TurnOff:$TurnOff } }
    $splat = @{ Name = $Name; Force = $Force; TurnOff = $TurnOff }
    # A job goes on after this returns: its caller holds the mutex around it when it matters (Stop-GpuVMBounded).
    if ($AsJob) { return Hyper-V\Stop-VM @splat -AsJob }
    Invoke-GpuPowerTransition -Name $Name -Do { Hyper-V\Stop-VM @splat }
}

function Restart-VM {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string]$Type, [switch]$Force, [switch]$Wait, [string]$For, [int]$Timeout)
    if (Test-GpuVMHcsMachine -Name $Name) { return Invoke-GpuPowerTransition -Name $Name -UntilUp -Do { Restart-HcsMachine -Name $Name -Wait:$Wait } }
    $splat = @{ Name = $Name; Force = $Force }
    if ($Type) { $splat['Type'] = $Type }
    if ($Wait) { $splat['Wait'] = $true; $splat['For'] = $For; $splat['Timeout'] = $Timeout }
    Assert-AgentMachineSwitch -Name $Name
    Invoke-GpuPowerTransition -Name $Name -UntilUp -Do { Hyper-V\Restart-VM @splat }
}
