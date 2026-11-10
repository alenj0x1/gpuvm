function Get-GpuVMInstalledApp {
    <#
    .SYNOPSIS
    The catalog apps installed in a VM. While it runs they are checked inside Windows; while it is off, the last ones
    GpuVM saw.
    .EXAMPLE
    Get-GpuVMInstalledApp -Name win10
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $state = Get-GpuVMState -Name $Name
    $installed = @(if ($state.Contains('installedApps')) { $state['installedApps'] | Where-Object { $_ } })
    $guest = Get-GpuVMGuestCredential -State $state
    if ($guest -and (Get-VM -Name $Name).State -eq 'Running' -and (Test-GuestHeartbeat -Name $Name)) {
        try {
            $installed = @(Get-GuestInstalledApp -Name $Name -Credential $guest)
            Update-InstalledAppState -Name $Name -Installed $installed -Replace
        }
        catch { Write-Verbose "No se pudo revisar las apps de la VM: $($_.Exception.Message)" }
    }
    $catalog = Get-AppCatalog
    foreach ($id in $installed) {
        if ($catalog.Contains($id)) { [ordered]@{ id = $id; name = $catalog[$id]['name'] } }
    }
}
