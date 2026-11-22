# Guest users are untrusted: what is verified or run as administrator goes in a new Administrators/SYSTEM-only folder,
# and folders that may hold junctions are deleted with rmdir /s /q (5.1's Remove-Item -Recurse follows junctions).
$script:GuestFolderCode = {
    $GpuVMAdminSid = 'S-1-5-32-544'
    $GpuVMSystemSid = 'S-1-5-18'
    $GpuVMUsersSid = 'S-1-5-32-545'

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

    # In PowerShell 7, where tests run, the same call lives in FileSystemAclExtensions.
    function New-GpuVMSecuredDirectory {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Security)
        if ([IO.Directory].GetMethod('CreateDirectory', [type[]]@([string], [Security.AccessControl.DirectorySecurity]))) { $null = [IO.Directory]::CreateDirectory($Path, $Security) }
        else { $null = [IO.FileSystemAclExtensions]::CreateDirectory($Security, $Path) }
    }

    # A file moved out of it must stay on its volume to keep the rights it was given.
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

    function Remove-GpuVMFolder {
        param([Parameter(Mandatory)][string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return }
        & "$env:SystemRoot\System32\cmd.exe" /d /c rmdir /s /q "`"$Path`"" 2>&1 | Out-Null
    }

    function Remove-GpuVMItem {
        param([Parameter(Mandatory)][string]$Path)
        if ([IO.Directory]::Exists($Path)) {
            $info = [IO.DirectoryInfo]::new($Path)
            if ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($Path, $false) } else { Remove-GpuVMFolder -Path $Path }
        }
        elseif ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) }
    }

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
            $acl = Get-Acl -LiteralPath $Path
            $extra = @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) |
                Where-Object { $_.IdentityReference.Value -notin $GpuVMAdminSid, $GpuVMSystemSid, $GpuVMUsersSid })
            if ($extra.Count) { foreach ($rule in $extra) { $null = $acl.RemoveAccessRuleSpecific($rule) }; Set-Acl -LiteralPath $Path -AclObject $acl }
            if (-not (Test-GpuVMLockedAcl -Acl (Get-Acl -LiteralPath $Path))) { throw "Couldn't restrict the permissions of $Path." }
        }
        if (-not $Deep) { return }
        # Top-down: each folder is taken back before it is listed, so nothing a user still controls is walked into.
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

    # The administrator only reads and deletes here, never writes: the user could turn it into a junction.
    function New-GpuVMUserFolder {
        param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$User)
        $sid = ([Security.Principal.NTAccount]$User).Translate([Security.Principal.SecurityIdentifier]).Value
        $dir = Join-Path $Root "run-$([guid]::NewGuid().ToString('n'))"
        New-GpuVMSecuredDirectory -Path $dir -Security (New-GpuVMFolderSecurity -Extra @(@($GpuVMUsersSid, 'ReadAndExecute'), @($sid, 'Modify')))
        $dir
    }

    # An open file inside (no delete sharing) pins it and every folder above until Close: what was checked is written to.
    function Enter-GpuVMDestination {
        param(
            [Parameter(Mandatory)][string]$ProfilePath,
            [Parameter(Mandatory)][string]$Desktop,
            [Parameter(Mandatory)][string]$Folder,
            [Parameter(Mandatory)][string]$Id,
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
                    # Older versions named it in Spanish: that folder becomes this one, with its files.
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
