function Invoke-GpuVMPower {
    <#
    .SYNOPSIS
    Power actions for any VM: Start, Shutdown (clean shutdown), TurnOff, Restart, Pause, Resume.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Start', 'Shutdown', 'TurnOff', 'Restart', 'Pause', 'Resume')][string]$Action
    )
    Assert-Admin
    switch ($Action) {
        'Start' { Assert-VMCanStart -Name $Name; Start-VM -Name $Name }
        'Shutdown' { Stop-VM -Name $Name -Force }
        'TurnOff' { Stop-VM -Name $Name -TurnOff -Force }
        # Reboot asks Windows to restart cleanly; Reset (the default) is like pulling the plug.
        'Restart' { Restart-VM -Name $Name -Type Reboot -Force }
        'Pause' { Suspend-VM -Name $Name }
        'Resume' { Resume-VM -Name $Name }
    }
    [ordered]@{ name = $Name; state = (Get-VM -Name $Name).State.ToString() }
}
