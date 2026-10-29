function Disconnect-GpuVMSharedDisk {
    <#
    .SYNOPSIS
    Detaches a shared disk from its VM, also while it runs (Windows takes the disk offline first, so nothing is
    left half-written).
    .EXAMPLE
    Disconnect-GpuVMSharedDisk -Name juegos
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name)
    Assert-Admin
    $disk = Read-SharedDisk -Name $Name
    $attachment = Get-SharedDiskAttachment -Path $disk['path']
    if (-not $attachment) { Write-Step "El disco '$Name' no está conectado"; return [ordered]@{ name = $Name; vm = $null } }
    $vmName = $attachment.VMName
    if ((Get-VM -Name $vmName).State -eq 'Running') {
        $guest = Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $vmName)
        if (-not $guest) { throw "Guarda la contraseña de Windows de '$vmName' o apágala para quitar el disco." }
        Write-Step "Cerrando el disco dentro de '$vmName'"
        $flushed = Invoke-Command -VMName $vmName -Credential $guest -ErrorAction Stop -ArgumentList $disk['label'] -ScriptBlock {
            param($label)
            $volume = Get-Volume -FileSystemLabel $label -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $volume) { return $true }
            $partition = Get-Partition | Where-Object { $_.AccessPaths -contains $volume.Path } | Select-Object -First 1
            # Offline flushes and closes the volume; it fails while a program has files open on it.
            try { Set-Disk -Number $partition.DiskNumber -IsOffline $true -ErrorAction Stop; $true } catch { $false }
        }
        if (-not [bool]$flushed) { throw "Hay programas usando el disco '$Name' dentro de '$vmName' (por ejemplo, un juego). Ciérralos y vuelve a intentarlo." }
    }
    Write-Step "Quitando el disco '$Name' de '$vmName'"
    $attachment | Remove-VMHardDiskDrive
    [ordered]@{ name = $Name; vm = $null }
}
