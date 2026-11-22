# Hyper-V refuses checkpoints on a VM with a GPU partition (even Off, even Standard): points are differencing disks.

$script:MaxRestorePoints = 10
$script:RestorePointFreeGB = 10
$script:RestorePointStateKeys = 'guest', 'streaming', 'installedApps', 'pendingApps', 'pendingRename', 'gpu', 'cleanup', 'edition'

function Get-RestorePointDirectory {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    Join-Path (Split-Path $State['vhdPath'] -Parent) 'points'
}

function Get-RestorePointPath {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State, [Parameter(Mandatory)][string]$Id)
    if ($Id -notmatch '^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$') { throw "That restore point isn't valid: $Id" }
    Join-Path (Get-RestorePointDirectory -State $State) "$Id.vhdx"
}

function Get-GpuVMRestorePointList {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    @(if ($State.Contains('restorePoints') -and $State['restorePoints']) { $State['restorePoints'] })
}

function Get-RestorePointChild {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State, [Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $candidates = @($State['vhdPath']) + @(Get-GpuVMRestorePointList -State $State | ForEach-Object { Get-RestorePointPath -State $State -Id $_['id'] })
    @(foreach ($candidate in $candidates) {
            if (-not (Test-Path -LiteralPath $candidate)) { continue }
            $vhd = Get-VHD -Path $candidate -ErrorAction SilentlyContinue
            if ($vhd -and $vhd.ParentPath -and [IO.Path]::GetFullPath($vhd.ParentPath) -eq $full) { $candidate }
        })
}

function Stop-GpuVMForDisk {
    param([Parameter(Mandatory)][string]$Name, [switch]$ShutdownIfRunning, [Parameter(Mandatory)][string]$Action)
    $vm = Get-VM -Name $Name -ErrorAction Stop
    if ($vm.State -eq 'Off') { return $false }
    if ($vm.State -ne 'Running' -or -not $ShutdownIfRunning) { throw "Shut down the machine '$Name' to $Action." }
    Write-Step 'Shutting the machine down'
    Stop-VM -Name $Name -Force -ErrorAction Stop
    $true
}

# Hyper-V grants a VM access to its disk file only on first attach: a file made again at that path needs the old one's entries.
function Copy-GpuVMDiskAccess {
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    $source = Get-Acl -LiteralPath $From
    $target = Get-Acl -LiteralPath $To
    $changed = $false
    foreach ($rule in $source.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow') { continue }
        $target.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($rule.IdentityReference, $rule.FileSystemRights, 'Allow'))
        $changed = $true
    }
    if ($changed) { Set-Acl -LiteralPath $To -AclObject $target }
}

function Update-GpuVMDiskAttachment {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $drive = Get-VMHardDiskDrive -VMName $Name | Where-Object { $_.Path -and [IO.Path]::GetFullPath($_.Path) -eq $full } | Select-Object -First 1
    if (-not $drive) { throw "The disk $Path isn't connected to the machine '$Name'." }
    Set-VMHardDiskDrive -VMName $Name -ControllerType $drive.ControllerType -ControllerNumber $drive.ControllerNumber `
        -ControllerLocation $drive.ControllerLocation -Path $Path -ErrorAction Stop
}

function Set-FileReadOnly {
    param([Parameter(Mandatory)][string]$Path, [bool]$Value)
    (Get-Item -LiteralPath $Path -Force).IsReadOnly = $Value
}

function Assert-GpuVMDiskInPlace {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][System.Collections.IDictionary]$State)
    $attached = @(Get-VMHardDiskDrive -VMName $Name | Where-Object Path | ForEach-Object { [IO.Path]::GetFullPath($_.Path) })
    if ([IO.Path]::GetFullPath($State['vhdPath']) -notin $attached) {
        throw "The disk of '$Name' isn't where GpuVM expects it ($($State['vhdPath']))."
    }
}

function New-RestorePointId {
    '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(2)).ToLowerInvariant())
}

function New-GpuVMRestorePointCore {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [string]$Label
    )
    Assert-GpuVMDiskInPlace -Name $Name -State $State
    $points = @(Get-GpuVMRestorePointList -State $State)
    if ($points.Count -ge $script:MaxRestorePoints) {
        throw "The machine already has $($points.Count) restore points, the most it can keep. Delete one to create another."
    }
    $freeGB = Get-DriveFreeGB $State['vhdPath']
    $needGB = $script:DiskMarginGB + $script:RestorePointFreeGB
    if ($freeGB -lt $needGB) { throw "There's no room for a restore point: $freeGB GB free and $needGB GB needed." }

    $id = New-RestorePointId
    $current = $State['vhdPath']
    $pointPath = Get-RestorePointPath -State $State -Id $id
    $dir = Split-Path $pointPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    if ((Get-Item -LiteralPath $dir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$dir is a link; GpuVM doesn't use it." }

    Write-Step 'Saving the restore point'
    $moved = $false
    try {
        [IO.File]::Move($current, $pointPath)
        $moved = $true
        New-VHD -Path $current -ParentPath $pointPath -Differencing -ErrorAction Stop | Out-Null
        Copy-GpuVMDiskAccess -From $pointPath -To $current
        Set-FileReadOnly -Path $pointPath -Value $true
        Update-GpuVMDiskAttachment -Name $Name -Path $current
    }
    catch {
        $failure = $_
        if ($moved) {
            if (Test-Path -LiteralPath $current) { Remove-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue }
            Set-FileReadOnly -Path $pointPath -Value $false
            [IO.File]::Move($pointPath, $current)
            try { Update-GpuVMDiskAttachment -Name $Name -Path $current } catch { Write-Warning $_.Exception.Message }
        }
        throw $failure
    }

    $snapshot = [ordered]@{}
    foreach ($key in $script:RestorePointStateKeys) { if ($State.Contains($key)) { $snapshot[$key] = Copy-Value $State[$key] } }
    $point = [ordered]@{
        id        = $id
        label     = if ($Label) { $Label.Trim() } else { $null }
        createdAt = (Get-Date).ToString('o')
        state     = $snapshot
    }
    $State['restorePoints'] = @($points) + @($point)
    Save-GpuVMState $State
    $point
}

function Restore-GpuVMRestorePointCore {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$Id
    )
    Assert-GpuVMDiskInPlace -Name $Name -State $State
    $point = Get-GpuVMRestorePointList -State $State | Where-Object { $_['id'] -eq $Id } | Select-Object -First 1
    if (-not $point) { throw "The restore point '$Id' doesn't exist." }
    $pointPath = Get-RestorePointPath -State $State -Id $Id
    if (-not (Test-Path -LiteralPath $pointPath)) { throw "The restore point's disk is missing ($pointPath)." }
    $current = $State['vhdPath']
    $top = Get-VHD -Path $current -ErrorAction Stop
    if ($top.VhdType -ne 'Differencing' -or -not $top.ParentPath) { throw "The disk of '$Name' isn't on a restore point." }
    $fresh = Join-Path (Split-Path $current -Parent) ".restore-$Id.vhdx"
    Write-Step 'Going back to the restore point'
    New-VHD -Path $fresh -ParentPath $pointPath -Differencing -ErrorAction Stop | Out-Null
    # Set aside, not deleted, until the new one is in place: the VM is never left without a disk.
    $aside = Join-Path (Split-Path $current -Parent) ".before-restore-$Id.vhdx"
    $setAside = $false
    try {
        Copy-GpuVMDiskAccess -From $current -To $fresh
        [IO.File]::Move($current, $aside)
        $setAside = $true
        [IO.File]::Move($fresh, $current)
    }
    catch {
        $failure = $_
        if ($setAside -and -not (Test-Path -LiteralPath $current)) { [IO.File]::Move($aside, $current) }
        if (Test-Path -LiteralPath $fresh) { Remove-Item -LiteralPath $fresh -Force -ErrorAction SilentlyContinue }
        throw $failure
    }
    Remove-Item -LiteralPath $aside -Force -ErrorAction SilentlyContinue
    Update-GpuVMDiskAttachment -Name $Name -Path $current
    foreach ($key in $script:RestorePointStateKeys) {
        if ($point['state'].Contains($key)) { $State[$key] = Copy-Value $point['state'][$key] }
        elseif ($State.Contains($key)) { $State.Remove($key) }
    }
    $State['restoredPoint'] = [ordered]@{ id = $Id; at = (Get-Date).ToString('o') }
    Save-GpuVMState $State
    $point
}

# Reparenting onto the merged disk skips Hyper-V's identity check on purpose: the content is the same.
function Remove-GpuVMRestorePointCore {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$Id
    )
    $points = @(Get-GpuVMRestorePointList -State $State)
    $point = $points | Where-Object { $_['id'] -eq $Id } | Select-Object -First 1
    if (-not $point) { throw "The restore point '$Id' doesn't exist." }
    $pointPath = Get-RestorePointPath -State $State -Id $Id
    $children = @(if (Test-Path -LiteralPath $pointPath) { Get-RestorePointChild -State $State -Path $pointPath })
    if ($children.Count -gt 1) { throw 'Two other points start from this one; delete one of them first.' }
    $vm = Get-VM -Name $Name -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $pointPath)) { Write-Warning "The point's disk was already gone ($pointPath)." }
    elseif (-not $children.Count) {
        Write-Step 'Deleting the restore point'
        Set-FileReadOnly -Path $pointPath -Value $false
        Remove-Item -LiteralPath $pointPath -Force
    }
    else {
        $child = $children[0]
        $childIsVM = [IO.Path]::GetFullPath($child) -eq [IO.Path]::GetFullPath($State['vhdPath'])
        if ($childIsVM -and $vm.State -ne 'Off') { throw "Shut down the machine '$Name' to delete this point." }
        $grandchildren = @(if (-not $childIsVM) { Get-RestorePointChild -State $State -Path $child })
        if ($grandchildren.Count -and $vm.State -ne 'Off') { throw "Shut down the machine '$Name' to delete this point." }
        Write-Step "Merging the point with what came after it ($([math]::Round((Get-Item -LiteralPath $child).Length / 1GB, 1)) GB)"
        Set-FileReadOnly -Path $pointPath -Value $false
        $childReadOnly = (Get-Item -LiteralPath $child).IsReadOnly
        Set-FileReadOnly -Path $child -Value $false
        Copy-GpuVMDiskAccess -From $child -To $pointPath
        try { Merge-VHD -Path $child -DestinationPath $pointPath -ErrorAction Stop }
        catch {
            # Merge-VHD leaves both files as they were when it fails before writing.
            if (Test-Path -LiteralPath $child) { Set-FileReadOnly -Path $child -Value $childReadOnly }
            Set-FileReadOnly -Path $pointPath -Value $true
            throw
        }
        [IO.File]::Move($pointPath, $child)
        if ($childReadOnly) { Set-FileReadOnly -Path $child -Value $true }
        foreach ($grandchild in $grandchildren) {
            $ro = (Get-Item -LiteralPath $grandchild).IsReadOnly
            Set-FileReadOnly -Path $grandchild -Value $false
            try { Set-VHD -Path $grandchild -ParentPath $child -IgnoreIdMismatch -ErrorAction Stop }
            finally { if ($ro) { Set-FileReadOnly -Path $grandchild -Value $true } }
        }
        if ($childIsVM -or $grandchildren.Count) { Update-GpuVMDiskAttachment -Name $Name -Path $State['vhdPath'] }
    }
    $State['restorePoints'] = @($points | Where-Object { $_['id'] -ne $Id })
    Save-GpuVMState $State
}

function Repair-GpuVMDiskChain {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To,
        [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$NewName
    )
    $disks = @($State['vhdPath']) + @(Get-GpuVMRestorePointList -State $State | ForEach-Object { Get-RestorePointPath -State $State -Id $_['id'] })
    foreach ($disk in $disks) {
        if (-not (Test-Path -LiteralPath $disk)) { continue }
        $vhd = Get-VHD -Path $disk -ErrorAction SilentlyContinue
        if (-not $vhd -or -not $vhd.ParentPath) { continue }
        $parent = Get-RenamedVMPath -Path $vhd.ParentPath -From $From -To $To -Name $Name -NewName $NewName
        if (-not $parent -or $parent -eq $vhd.ParentPath -or -not (Test-Path -LiteralPath $parent)) { continue }
        $ro = (Get-Item -LiteralPath $disk).IsReadOnly
        Set-FileReadOnly -Path $disk -Value $false
        try { Set-VHD -Path $disk -ParentPath $parent -ErrorAction Stop }
        finally { if ($ro) { Set-FileReadOnly -Path $disk -Value $true } }
    }
}

function Get-GpuVMRestorePointView {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    $current = $State['vhdPath']
    $onPath = $null
    $topBytes = 0
    if (Test-Path -LiteralPath $current) {
        $top = Get-VHD -Path $current -ErrorAction SilentlyContinue
        if ($top) { $topBytes = $top.FileSize; if ($top.ParentPath) { $onPath = [IO.Path]::GetFullPath($top.ParentPath) } }
    }
    $list = foreach ($point in Get-GpuVMRestorePointList -State $State) {
        $path = Get-RestorePointPath -State $State -Id $point['id']
        $exists = Test-Path -LiteralPath $path
        [ordered]@{
            id        = $point['id']
            label     = $point['label']
            createdAt = $point['createdAt']
            sizeGB    = if ($exists) { [math]::Round((Get-Item -LiteralPath $path).Length / 1GB, 2) } else { $null }
            missing   = -not $exists
            current   = $onPath -and $exists -and ([IO.Path]::GetFullPath($path) -eq $onPath)
        }
    }
    [ordered]@{
        points       = @($list)
        max          = $script:MaxRestorePoints
        changesGB    = if ($onPath) { [math]::Round($topBytes / 1GB, 2) } else { $null }
        restoredFrom = if ($State.Contains('restoredPoint')) { $State['restoredPoint'] } else { $null }
    }
}
