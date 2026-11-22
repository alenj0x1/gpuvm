# Folders GpuVM touches inside a guest as its administrator (PowerShell Direct), while the guest's own users are
# untrusted: on an agent machine `agent`, and anything it runs, may be hostile (security review 2026-11-21). A folder
# such a user can write is one where it can swap a file between a check and its use, or plant a junction that turns an
# administrator's write or delete into one anywhere on the disk. So:
# - what is verified or run as administrator is copied first into a new folder only Administrators and SYSTEM can
#   open, under %SystemRoot%\Temp, created with that ACL already in place (no moment with inherited rights);
# - C:\GpuVM (which would inherit "Authenticated Users: Modify" from C:\) is Administrators/SYSTEM full, Users read and
#   run, nothing inherited;
# - a folder that may hold reparse points is deleted with `rmdir /s /q`, which removes a junction without entering it
#   (Windows PowerShell 5.1's Remove-Item -Recurse goes into junctions and deletes what they point to).
# Guest code (Windows PowerShell 5.1), sent as text and dot-sourced where it is needed.
$script:GuestFolderCode = {
    $GpuVMAdminSid = 'S-1-5-32-544'
    $GpuVMSystemSid = 'S-1-5-18'
    $GpuVMUsersSid = 'S-1-5-32-545'

    # Administrators and SYSTEM full control, inherited by everything inside; nothing from the parent; owned by
    # Administrators. $Extra adds more rules ([sid, rights] pairs) with the same inheritance.
    function New-GpuVMFolderSecurity {
        param([object[]]$Extra = @())
        $security = New-Object Security.AccessControl.DirectorySecurity
        $security.SetAccessRuleProtection($true, $false)
        $security.SetOwner((New-Object Security.Principal.SecurityIdentifier $GpuVMAdminSid))
        $rules = @(, @($GpuVMAdminSid, 'FullControl')) + @(, @($GpuVMSystemSid, 'FullControl')) + $Extra
        foreach ($rule in $rules) {
            $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule (
                (New-Object Security.Principal.SecurityIdentifier $rule[0]), $rule[1], 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
        }
        $security
    }

    # Created with $Security from its first moment (CreateDirectory with a security descriptor; in PowerShell 7, where
    # tests run, the same call lives in FileSystemAclExtensions).
    function New-GpuVMSecuredDirectory {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Security)
        if ([IO.Directory].GetMethod('CreateDirectory', [type[]]@([string], [Security.AccessControl.DirectorySecurity]))) { $null = [IO.Directory]::CreateDirectory($Path, $Security) }
        else { $null = [IO.FileSystemAclExtensions]::CreateDirectory($Security, $Path) }
    }

    # A new folder with that ACL from the moment it exists: under %SystemRoot%\Temp, or at the root of $Volume when
    # that is another drive (a file moved out of it must stay on its volume to keep the rights it was given).
    function New-GpuVMAdminFolder {
        param([string]$Volume, [string]$Prefix = 'GpuVM', [object[]]$Extra = @())
        $temp = Join-Path $env:SystemRoot 'Temp'
        $parent = if ($Volume -and -not [string]::Equals([IO.Path]::GetPathRoot($temp), $Volume, [StringComparison]::OrdinalIgnoreCase)) { $Volume } else { $temp }
        $dir = Join-Path $parent "$Prefix-$([guid]::NewGuid().ToString('n'))"
        if (Test-Path -LiteralPath $dir) { throw "$dir already exists." }
        New-GpuVMSecuredDirectory -Path $dir -Security (New-GpuVMFolderSecurity -Extra $Extra)
        # CreateDirectory also returns a folder that was already there: it must be ours, as created.
        $acl = Get-Acl -LiteralPath $dir
        $reparse = [IO.DirectoryInfo]::new($dir).Attributes -band [IO.FileAttributes]::ReparsePoint
        if ($reparse -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $GpuVMAdminSid -or -not $acl.AreAccessRulesProtected) {
            throw "$dir isn't the folder GpuVM created."
        }
        $dir
    }

    # Deletes a folder and what is in it without following any junction or link inside (they are removed as links).
    function Remove-GpuVMFolder {
        param([Parameter(Mandatory)][string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return }
        & "$env:SystemRoot\System32\cmd.exe" /d /c rmdir /s /q "`"$Path`"" 2>&1 | Out-Null
    }

    # Deletes one file (or a link, as a link) so the administrator can write a new one in its place: never through a
    # hard link or file someone left there.
    function Remove-GpuVMItem {
        param([Parameter(Mandatory)][string]$Path)
        if ([IO.Directory]::Exists($Path)) {
            $info = [IO.DirectoryInfo]::new($Path)
            if ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($Path, $false) } else { Remove-GpuVMFolder -Path $Path }
        }
        elseif ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) }
    }

    # True when the folder is owned by Administrators/SYSTEM, inherits nothing, and only they can write it.
    function Test-GpuVMLockedAcl {
        param([Parameter(Mandatory)]$Acl)
        $admins = @($GpuVMAdminSid, $GpuVMSystemSid)
        # WriteData, AppendData, WriteEA, DeleteChild, WriteAttributes, Delete, WRITE_DAC, WRITE_OWNER, GENERIC_ALL, GENERIC_WRITE.
        $writeMask = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
        if ($Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $admins -or -not $Acl.AreAccessRulesProtected) { return $false }
        foreach ($rule in $Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -ne 'Allow' -or $rule.IdentityReference.Value -in $admins) { continue }
            if (([int64]$rule.FileSystemRights -band $writeMask) -ne 0) { return $false }
        }
        $true
    }

    # C:\GpuVM as Administrators/SYSTEM full and Users read & run, nothing inherited. Cheap when it already is (one
    # Get-Acl). -Deep also goes through what is inside (once per machine): links are removed, and anything a user made
    # while it was writable (and owns, so could still change) is taken back for Administrators.
    function Protect-GpuVMGuestRoot {
        param([string]$Path = 'C:\GpuVM', [switch]$Deep)
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($item -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $item.PSIsContainer)) {
            # A link (or a file) in its place, planted while C:\ let users create it: removed itself, never followed.
            if ($item.PSIsContainer) { [IO.Directory]::Delete($Path, $false) } else { [IO.File]::Delete($Path) }
            $item = $null
        }
        if (-not $item) {
            New-GpuVMSecuredDirectory -Path $Path -Security (New-GpuVMFolderSecurity -Extra @(, @($GpuVMUsersSid, 'ReadAndExecute')))
        }
        # A DACL that hides itself from Administrators counts as not restricted (takeown gets it back).
        $locked = try { Test-GpuVMLockedAcl -Acl (Get-Acl -LiteralPath $Path) } catch { $false }
        if (-not $locked) {
            & "$env:SystemRoot\System32\takeown.exe" /F $Path /A 2>&1 | Out-Null
            & "$env:SystemRoot\System32\icacls.exe" $Path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /Q 2>&1 | Out-Null
            # Explicit grants other than those three (a user's own) are removed.
            $acl = Get-Acl -LiteralPath $Path
            $extra = @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) |
                Where-Object { $_.IdentityReference.Value -notin $GpuVMAdminSid, $GpuVMSystemSid, $GpuVMUsersSid })
            if ($extra.Count) { foreach ($rule in $extra) { $null = $acl.RemoveAccessRuleSpecific($rule) }; Set-Acl -LiteralPath $Path -AclObject $acl }
            if (-not (Test-GpuVMLockedAcl -Acl (Get-Acl -LiteralPath $Path))) { throw "Couldn't restrict the permissions of $Path." }
        }
        if (-not $Deep) { return }
        # Top-down: each folder is taken back before what is in it is listed, so nothing a user still controls is
        # walked into (the folder above it already lets no user add or rename anything).
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push($Path)
        while ($pending.Count) {
            foreach ($child in [IO.DirectoryInfo]::new($pending.Pop()).GetFileSystemInfos()) {
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    if ($child -is [IO.DirectoryInfo]) { [IO.Directory]::Delete($child.FullName, $false) } else { [IO.File]::Delete($child.FullName) }
                    continue
                }
                $owner = try { (Get-Acl -LiteralPath $child.FullName).GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { '' }
                if ($owner -notin $GpuVMAdminSid, $GpuVMSystemSid) {
                    & "$env:SystemRoot\System32\takeown.exe" /F $child.FullName /A 2>&1 | Out-Null
                    # Only what C:\GpuVM gives (no /T: a folder's own reset reaches what is inside it).
                    & "$env:SystemRoot\System32\icacls.exe" $child.FullName /reset /Q 2>&1 | Out-Null
                }
                if ($child -is [IO.DirectoryInfo]) { $pending.Push($child.FullName) }
            }
        }
    }

    # A folder inside C:\GpuVM that one user (a task GpuVM runs in that user's session) can write its answer into.
    # The administrator only reads from it and deletes it with Remove-GpuVMFolder: never writes there, since the user
    # could turn it into a junction.
    function New-GpuVMUserFolder {
        param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$User)
        $sid = ([Security.Principal.NTAccount]$User).Translate([Security.Principal.SecurityIdentifier]).Value
        $dir = Join-Path $Root "run-$([guid]::NewGuid().ToString('n'))"
        New-GpuVMSecuredDirectory -Path $dir -Security (New-GpuVMFolderSecurity -Extra @(@($GpuVMUsersSid, 'ReadAndExecute'), @($sid, 'Modify')))
        $dir
    }

    # The folder files are received in (Desktop\<Folder> of the person), checked and held while the administrator
    # works in it: it must be under the person's profile, and neither it nor any folder above it a junction or link
    # (`agent` owns its desktop and could point Received anywhere). An open file inside (no delete sharing) keeps
    # Windows from renaming or deleting it or any folder above it until Close, and a folder that isn't empty can't
    # become a junction: what was checked is what is written to. Returns @{ Dest; Close = { … } } or throws.
    function Enter-GpuVMDestination {
        param(
            [Parameter(Mandatory)][string]$ProfilePath,
            [Parameter(Mandatory)][string]$Desktop,
            [Parameter(Mandatory)][string]$Folder,
            [Parameter(Mandatory)][string]$Id,
            # Creates the folder (and migrates "Recibidos" when it is "Received").
            [switch]$Create
        )
        $profileFull = [IO.Path]::GetFullPath($ProfilePath).TrimEnd('\')
        $desktopFull = [IO.Path]::GetFullPath($Desktop).TrimEnd('\')
        if ($desktopFull.IndexOf(':', 2) -ge 0 -or $desktopFull -notmatch '^[A-Za-z]:\\' -or
            -not $desktopFull.StartsWith("$profileFull\", [StringComparison]::OrdinalIgnoreCase)) {
            throw "The desktop ($desktopFull) isn't inside the user's profile ($profileFull); nothing is copied."
        }
        $dest = Join-Path $desktopFull $Folder
        $assertPlain = {
            param([string]$Path)
            for ($p = $Path; $p -and $p.Length -gt 3; $p = [IO.Path]::GetDirectoryName($p)) {
                $info = [IO.DirectoryInfo]::new($p)
                if (-not $info.Exists) {
                    # Something that isn't a folder (a file, a link to a file) in its place.
                    if (Test-Path -LiteralPath $p) { throw "$p isn't a folder; nothing is copied." }
                    continue
                }
                if ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$p is a link to another place; nothing is copied." }
            }
        }
        $locks = [Collections.Generic.List[IDisposable]]::new()
        $hold = {
            param([string]$Dir)
            $file = Join-Path $Dir ".gpuvm-lock-$Id"
            $stream = [IO.FileStream]::new($file, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite, [int]1, [IO.FileOptions]::DeleteOnClose)
            $locks.Add($stream)
            try { [IO.File]::SetAttributes($file, 'Hidden') } catch { }
        }
        try {
            if (-not [IO.Directory]::Exists($desktopFull)) { throw "The desktop ($desktopFull) doesn't exist; nothing is copied." }
            & $assertPlain $desktopFull
            & $hold $desktopFull
            # Checked again once held: a swap between the first check and the hold shows now.
            & $assertPlain $desktopFull
            if ($Create) {
                if ($Folder -eq 'Received') {
                    # Versions before 0.9 named it in Spanish: that folder becomes this one, with its files.
                    $old = Join-Path $desktopFull 'Recibidos'
                    if (-not (Test-Path -LiteralPath $dest) -and (Test-Path -LiteralPath $old)) { Rename-Item -LiteralPath $old -NewName $Folder }
                }
                if (-not (Test-Path -LiteralPath $dest)) { $null = [IO.Directory]::CreateDirectory($dest) }
            }
            & $assertPlain $dest
            if (-not [IO.Directory]::Exists($dest)) { throw "$dest isn't a folder; nothing is copied." }
            & $hold $dest
            & $assertPlain $dest
        }
        catch {
            foreach ($l in $locks) { $l.Dispose() }
            throw
        }
        @{ Dest = $dest; Close = { foreach ($l in $locks) { $l.Dispose() } }.GetNewClosure() }
    }
}.ToString()

# A new folder in the guest only Administrators and SYSTEM can open (New-GpuVMAdminFolder), for files that are
# verified and then run or compiled there as administrator: no user of the guest can swap them in between.
function New-GuestAdminFolder {
    param([Parameter(Mandatory)]$Session, [string]$Prefix = 'GpuVM')
    $dir = Invoke-Command -Session $Session -ErrorAction Stop -ArgumentList $script:GuestFolderCode, $Prefix -ScriptBlock {
        param($folderCode, $prefix)
        . ([scriptblock]::Create($folderCode))
        New-GpuVMAdminFolder -Prefix $prefix
    }
    $dir = ConvertTo-GuestString (@($dir)[-1]) -MaxLength 260
    if ($dir -notmatch '^[A-Za-z]:\\[^"*?<>|]+$') { throw "The machine didn't create a folder for the installer." }
    $dir
}

function Remove-GuestAdminFolder {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Path)
    Invoke-Command -Session $Session -ErrorAction SilentlyContinue -ArgumentList $script:GuestFolderCode, $Path -ScriptBlock {
        param($folderCode, $path)
        . ([scriptblock]::Create($folderCode))
        Remove-GpuVMFolder -Path $path
    }
}

# C:\GpuVM restricted once per machine (Protect-GpuVMGuestRoot -Deep), for machines made before it was created that
# way (security review 2026-11-21). Remembered in the machine's state, so later opens don't ask the guest again.
function Protect-GuestGpuVMRoot {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][pscredential]$Credential)
    $state = Get-GpuVMState -Name $Name
    if ($state.Contains('guestRootLocked') -and $state['guestRootLocked']) { return }
    Invoke-Guest -Name $Name -Credential $Credential -ArgumentList $script:GuestFolderCode -ScriptBlock {
        param($folderCode)
        . ([scriptblock]::Create($folderCode))
        Protect-GpuVMGuestRoot -Path (Join-Path $env:SystemDrive 'GpuVM') -Deep
    } | Out-Null
    $state = Get-GpuVMState -Name $Name
    $state['guestRootLocked'] = $true
    Save-GpuVMState $state
}
