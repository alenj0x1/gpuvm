function Get-GpuVMPlatform {
    <#
    .SYNOPSIS
    What this PC runs machines with: Hyper-V where Windows has it, the Host Compute Service elsewhere (Home), and
    whether Windows' "Virtual Machine Platform" still has to be turned on (or is waiting for a restart).
    #>
    [CmdletBinding()]
    param()
    $hyperV = Test-HyperVRole
    $vmp = Get-VirtualMachinePlatformState
    $hcs = [bool](Get-Service vmcompute -ErrorAction SilentlyContinue)
    $ready = $hyperV -or ($vmp -eq 'Enabled' -and $hcs)
    [ordered]@{
        backend        = if ($hyperV) { 'hyperv-gpup' } else { 'hcs' }
        hyperV         = $hyperV
        platform       = $vmp
        ready          = $ready
        # Turned on, but Windows finishes it at the next restart (the Host Compute Service isn't there yet).
        restartPending = -not $ready -and $vmp -eq 'Enabled' -and -not $hcs
        canEnable      = -not $ready -and $vmp -eq 'Disabled'
    }
}
