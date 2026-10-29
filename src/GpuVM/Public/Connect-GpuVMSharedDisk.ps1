function Connect-GpuVMSharedDisk {
    <#
    .SYNOPSIS
    Attaches a shared disk to a VM, also while it runs. If another VM has it and is off, it moves; if that VM is
    running, disconnect it there first. Inside the VM the disk gets a drive letter (and SteamLibrary, for games).
    .EXAMPLE
    Connect-GpuVMSharedDisk -Name juegos -VMName win10
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name,
        [Parameter(Mandatory)][string]$VMName
    )
    Assert-Admin
    $disk = Read-SharedDisk -Name $Name
    $state = Get-GpuVMState -Name $VMName
    $attachment = Get-SharedDiskAttachment -Path $disk['path']
    if ($attachment -and $attachment.VMName -ne $VMName) {
        if ((Get-VM -Name $attachment.VMName).State -ne 'Off') {
            throw "El disco '$Name' está conectado a '$($attachment.VMName)', que está encendida. Desconéctalo ahí primero."
        }
        Write-Step "Quitando el disco de '$($attachment.VMName)'"
        $attachment | Remove-VMHardDiskDrive
        $attachment = $null
    }
    if (-not $attachment) {
        Write-Step "Conectando el disco '$Name' a '$VMName'"
        Add-VMHardDiskDrive -VMName $VMName -ControllerType SCSI -Path $disk['path']
    }
    $letter = $null
    $guest = Get-GpuVMGuestCredential -State $state
    # With the VM off, the drive letter and Steam library are set the next time it is opened (Connect-GpuVM).
    if ((Get-VM -Name $VMName).State -eq 'Running' -and $guest) {
        $letter = Initialize-GuestSharedDisk -VMName $VMName -Credential $guest -Disk $disk
    }
    [ordered]@{ name = $Name; vm = $VMName; letter = $letter }
}
