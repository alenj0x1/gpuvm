function Stop-GpuVMAll {
    <#
    .SYNOPSIS
    Shuts down (cleanly, like the Start menu inside Windows) every running VM created with GpuVM, all at once.
    The app runs it when it quits, if "Al cerrar GpuVM: apagar las máquinas" is chosen.
    #>
    [CmdletBinding()]
    param([int]$TimeoutSec = 180)
    Assert-Admin
    $running = @(Get-VM | Where-Object State -eq 'Running' | Where-Object {
            try { [bool](Get-GpuVMState -Name $_.Name) } catch { $false }
        })
    if (-not $running) { return }
    Write-Step "Apagando $(($running.Name) -join ', ')"
    $jobs = foreach ($vm in $running) { Stop-VM -Name $vm.Name -Force -AsJob }
    $null = $jobs | Wait-Job -Timeout $TimeoutSec
    $jobs | Remove-Job -Force
    foreach ($vm in $running) { [ordered]@{ name = $vm.Name; state = (Get-VM -Name $vm.Name).State.ToString() } }
}
