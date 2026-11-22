function Stop-GpuVMAll {
    <#
    .SYNOPSIS
    Shuts down (cleanly, like the Start menu inside Windows) every running VM created with GpuVM, all at once.
    The app runs it when it quits, if "When quitting GpuVM: Shut them down" is chosen.
    #>
    [CmdletBinding()]
    param([int]$TimeoutSec = 180)
    Assert-Admin
    $running = @(Get-VM | Where-Object State -eq 'Running' | Where-Object {
            try { [bool](Get-GpuVMState -Name $_.Name) } catch { $false }
        })
    if (-not $running) { return }
    Write-Step "Shutting down $(($running.Name) -join ', ')"
    foreach ($vm in $running) { $null = Register-GuestUpdateBeforeShutdown -Name $vm.Name }
    $jobs = foreach ($vm in $running) { Stop-VM -Name $vm.Name -Force -AsJob }
    $null = $jobs | Wait-Job -Timeout $TimeoutSec
    # Only finished jobs: removing one Hyper-V hasn't completed yet ends the PowerShell process.
    $jobs | Where-Object { $_.State -in 'Completed', 'Failed', 'Stopped' } | Remove-Job -Force
    foreach ($vm in $running) { [ordered]@{ name = $vm.Name; state = (Get-VM -Name $vm.Name).State.ToString() } }
}
