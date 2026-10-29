function New-GpuVMSharedDisk {
    <#
    .SYNOPSIS
    Creates a shared disk: a dynamic data disk (it only takes the space its files use) that you attach to one VM at a
    time. With -Purpose games, attaching it prepares SteamLibrary and adds it to Steam's libraries in the VM.
    .EXAMPLE
    New-GpuVMSharedDisk -Name juegos -SizeGB 500 -Purpose games
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name,
        [ValidateRange(8, 65536)][int]$SizeGB = 256,
        [ValidateSet('games', 'general')][string]$Purpose = 'games'
    )
    Assert-Admin
    $path = Get-SharedDiskPath -Name $Name
    if (Test-Path -LiteralPath $path) { throw "Ya existe un disco compartido llamado '$Name'." }
    if (-not $PSCmdlet.ShouldProcess($Name, "Crear disco compartido de $SizeGB GB")) { return }
    Initialize-GpuVMRoot -Path (Get-GpuVMDefaultRoot)
    New-Item -ItemType Directory -Path (Get-SharedDiskRoot) -Force | Out-Null
    Protect-GpuVMSharedFolder -Path (Get-SharedDiskRoot)
    try {
        Write-Step "Creando el disco '$Name' de $SizeGB GB"
        New-VHD -Path $path -SizeBytes ([uint64]$SizeGB * 1GB) -Dynamic | Out-Null
        # Formatted here, without a drive letter on this PC; the VM gives it one when it is attached.
        Mount-VHD -Path $path -NoDriveLetter
        try {
            $number = (Get-VHD -Path $path).DiskNumber
            Initialize-Disk -Number $number -PartitionStyle GPT
            $partition = New-Partition -DiskNumber $number -UseMaximumSize
            Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel (Get-SharedDiskLabel $Name) -Confirm:$false | Out-Null
        }
        finally { Dismount-VHD -Path $path }
        Write-JsonFile -Path ([IO.Path]::ChangeExtension($path, '.json')) -Data ([ordered]@{ purpose = $Purpose; createdAt = (Get-Date).ToString('o') })
    }
    catch {
        if ((Get-VHD -Path $path -ErrorAction SilentlyContinue).Attached) { Dismount-VHD -Path $path -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $path, ([IO.Path]::ChangeExtension($path, '.json')) -Force -ErrorAction SilentlyContinue
        throw
    }
    Write-Step "Disco '$Name' listo"
    Get-GpuVMSharedDisk | Where-Object { $_['name'] -eq $Name }
}
