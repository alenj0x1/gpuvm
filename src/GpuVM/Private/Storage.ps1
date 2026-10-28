# Disks and ISOs: the folder where GpuVM keeps VMs, growing the guest's C: and the library of used ISOs.

# Where GpuVM keeps VM folders. Read from the installed base profile, never from a VM's own state file,
# so a tampered gpuvm.json cannot point deletions somewhere else.
function Get-GpuVMDefaultRoot {
    $base = Read-JsonFile (Join-Path (Get-ProfileDirectory) 'base.json')
    [IO.Path]::GetFullPath($base['vm']['root']).TrimEnd('\')
}

function Get-DriveFreeGB {
    param([Parameter(Mandatory)][string]$Path)
    [math]::Floor(([IO.DriveInfo]::new((Split-Path $Path -Qualifier))).AvailableFreeSpace / 1GB)
}

# Grows the guest's C: into the free space at the end of its disk (after Resize-VHD), from inside the guest.
function Expand-GuestSystemDisk {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    $grown = Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock {
        $partition = Get-Partition -DriveLetter C
        $max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
        if ($max - $partition.Size -lt 1GB) { return 0 }
        Resize-Partition -DriveLetter C -Size $max
        [math]::Round($max / 1GB)
    }
    $sizeGB = [int]$grown
    if ($sizeGB -gt 0) { Write-Step "Disco C: de la VM ampliado a $sizeGB GB" }
}

function Get-IsoLibraryPath { Get-DataPath 'isos.json' }

function Read-IsoLibrary {
    $path = Get-IsoLibraryPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    @((Read-JsonFile $path)['isos'] | Where-Object { $_ })
}

function Save-IsoLibrary {
    param([object[]]$Entries)
    Write-JsonFile -Path (Get-IsoLibraryPath) -Data ([ordered]@{ isos = @($Entries) })
}

# Remembers an ISO (and which VM used it) so the "Create machine" wizard offers it again.
function Register-GpuVMIsoUse {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$VMName
    )
    $full = [IO.Path]::GetFullPath($Path)
    $entries = [System.Collections.Generic.List[object]]::new()
    $entry = $null
    foreach ($e in Read-IsoLibrary) {
        if ($e['path'] -eq $full) { $entry = $e } else { $entries.Add($e) }
    }
    if (-not $entry) { $entry = [ordered]@{ path = $full; addedAt = (Get-Date).ToString('o'); lastUsed = $null; usedBy = @() } }
    if ($VMName) {
        $entry['lastUsed'] = (Get-Date).ToString('o')
        $entry['usedBy'] = @(@($entry['usedBy']) + $VMName | Where-Object { $_ } | Select-Object -Unique)
    }
    $entries.Insert(0, $entry)
    Save-IsoLibrary $entries
}
