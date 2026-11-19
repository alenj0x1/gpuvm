# Restore points: a stopped VM's disk frozen as it is, so the VM can go back to it later. Hyper-V refuses
# checkpoints on a VM with a GPU partition (even Off, even Standard: lab 045), so GpuVM builds its own with
# differencing disks. Creating a point moves the VM's disk to <vmDir>\Virtual Hard Disks\points\<id>.vhdx (read-only)
# and puts an empty differencing disk on top of it at the VM's usual disk path; the VM keeps writing only there.
# Going back throws that top disk away and starts a new empty one on the point. Deleting a point merges what sits on
# it into it. The VM's disk path never changes, so nothing else in GpuVM needs to know points exist.
# Only Windows' disk goes back: the VM's settings (processors, memory, GPU) stay as they are now. What GpuVM knows
# about what is inside Windows (installed apps, password, Sunshine pairing, driver version) is saved with each point
# and comes back with it.

$script:MaxRestorePoints = 10
# Free space a point asks for on top of the host's margin: what the VM writes after it lands in a new disk.
$script:RestorePointFreeGB = 10
# State that describes what is inside the guest's disk, so it goes back with the disk.
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

# The disks that sit directly on $Path: the VM's own disk and other points (a branch after going back).
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

# Points are taken and applied with the VM off. -ShutdownIfRunning shuts it down cleanly (the guest closes its apps)
# and returns $true so the caller starts it again afterwards.
function Stop-GpuVMForDisk {
    param([Parameter(Mandatory)][string]$Name, [switch]$ShutdownIfRunning, [Parameter(Mandatory)][string]$Action)
    $vm = Get-VM -Name $Name -ErrorAction Stop
    if ($vm.State -eq 'Off') { return $false }
    if ($vm.State -ne 'Running' -or -not $ShutdownIfRunning) { throw "Shut down the machine '$Name' to $Action." }
    Write-Step 'Shutting the machine down'
    Stop-VM -Name $Name -Force -ErrorAction Stop
    $true
}

# Hyper-V gives each VM its own read/write entry on its disk file (NT VIRTUAL MACHINE\<VM id>) when the disk is
# attached. A file made again at the same path doesn't have it, and attaching the same path again doesn't add it
# (lab 045: "Account does not have permission to open attachment"). So the new file gets the explicit entries the
# VM's previous disk file had: that VM's own access, nothing more.
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

# Takes a point of a stopped VM. Returns the point's record.
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
        # Same folder tree, same volume: a rename, nothing is copied.
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

# Puts the VM's disk back as it was at $Id: the current top disk is thrown away and an empty one starts on the point.
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
    # The VM's disk is only ever a top disk on a point: never a point or a template (they are other disks).
    $fresh = Join-Path (Split-Path $current -Parent) ".restore-$Id.vhdx"
    Write-Step 'Going back to the restore point'
    New-VHD -Path $fresh -ParentPath $pointPath -Differencing -ErrorAction Stop | Out-Null
    # The current top disk is set aside (not deleted) until the new one is in its place: if anything fails, it goes back
    # and the VM is never left without a disk.
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

# Deletes a point. What sits on it is merged into it (the VM keeps what it has now): a point nothing sits on is
# just deleted; the VM's own disk is merged into it; another point is merged into it and that point's disks are
# pointed at the result (same content, so Hyper-V's identity check is skipped on purpose). A point two others sit
# on (after going back) can't be deleted until one of them is.
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
        # The merged file takes the child's place: it gets the VM's access the child had.
        Copy-GpuVMDiskAccess -From $child -To $pointPath
        try { Merge-VHD -Path $child -DestinationPath $pointPath -ErrorAction Stop }
        catch {
            # Merge-VHD leaves both files as they were when it fails before writing.
            if (Test-Path -LiteralPath $child) { Set-FileReadOnly -Path $child -Value $childReadOnly }
            Set-FileReadOnly -Path $pointPath -Value $true
            throw
        }
        # The merged disk takes the child's place (its path is what the VM or the other disks know).
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

# After a VM's folder moved (rename), each disk of its chain is pointed at its parent's new path.
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

# What the app shows: each point with its date and what it takes on disk (its own layer; the oldest one is the
# disk the VM had before the first point), plus what the VM wrote since the point it is on.
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
