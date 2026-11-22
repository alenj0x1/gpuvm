function Rename-GpuVM {
    <#
    .SYNOPSIS
    Renames a VM: in Hyper-V, its folder and disk, and GpuVM's own state (settings, Moonlight pairing and client
    preferences, last opened). The VM must be off. If a step fails, what was already renamed is undone.
    .EXAMPLE
    Rename-GpuVM -Name win10 -NewName juegos
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$NewName
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    if ($NewName -ceq $Name) { return Get-GpuVM -Name $Name }
    $vm = Get-VM -Name $Name -ErrorAction Stop
    if ($vm.State -ne 'Off') { throw "Turn off the VM '$Name' to rename it." }
    if (@(Get-VMSnapshot -VMName $Name -ErrorAction SilentlyContinue).Count) {
        throw "The VM '$Name' has checkpoints; delete them in Hyper-V Manager to rename it."
    }
    $root = if ($NewName -ne $Name) { Split-Path ([IO.Path]::GetFullPath($state['vmDir']).TrimEnd('\')) -Parent }
    Assert-GpuVMNameFree -Name $NewName -Root $root -Except $vm.Id
    if (-not $PSCmdlet.ShouldProcess($Name, "Rename to $NewName")) { return }

    Close-GuestSession -Name $Name
    Invoke-GpuVMBackend -Backend $state['backend'] -Operation Rename -Arguments $Name, $NewName, $state | Out-Null
    # The ISO list only remembers which VMs used each ISO: a failure there never undoes the rename.
    try { Rename-GpuVMIsoUse -Name $Name -NewName $NewName }
    catch { Write-Warning "Couldn't update the ISO list: $($_.Exception.Message)" }
    try { Update-GpuVMAgentRegistration -Name $NewName }
    catch { Write-Warning "Couldn't update the agent's registration: $($_.Exception.Message)" }
    Write-Step "The VM is now called '$NewName'."
    Get-GpuVM -Name $NewName
}
