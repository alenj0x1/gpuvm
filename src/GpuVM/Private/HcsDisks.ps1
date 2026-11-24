# Disk commands without Hyper-V's module (Windows Home): the same names the module already uses, served by Hyper-V
# when it is there and otherwise by GpuVM's own disk engine (gpuvm-host hcs vhd-*) and Windows' Storage module.

function Get-VHD {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipelineByPropertyName)][Alias('FullName')][string]$Path)
    process {
        if ($script:HyperVAvailable) { return Hyper-V\Get-VHD -Path $Path }
        # A query: its failures are non-terminating like Hyper-V's, so callers' -ErrorAction applies.
        try {
            $full = (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName
            $info = Invoke-GpuVMHcs @('vhd-info', $full)
        }
        catch {
            $PSCmdlet.WriteError([Management.Automation.ErrorRecord]::new($_.Exception, 'GetVHD', 'ObjectNotFound', $Path))
            return
        }
        $image = Get-DiskImage -ImagePath $full -ErrorAction SilentlyContinue
        $attached = [bool]($image -and $image.Attached)
        [pscustomobject]@{
            Path       = $full
            Size       = [uint64]$info['size']
            FileSize   = [uint64]$info['fileSize']
            ParentPath = $info['parentPath']
            VhdType    = if ($info['parentPath']) { 'Differencing' } else { 'Dynamic' }
            Attached   = $attached
            DiskNumber = if ($attached) { $image.Number } else { $null }
        }
    }
}

function New-VHD {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [uint64]$SizeBytes, [string]$ParentPath, [switch]$Dynamic, [switch]$Differencing, [switch]$Fixed)
    if ($script:HyperVAvailable) { return Hyper-V\New-VHD @PSBoundParameters }
    if ($ParentPath) { $null = Invoke-GpuVMHcs @('vhd-new', $Path, '--parent', $ParentPath) }
    else { $null = Invoke-GpuVMHcs @('vhd-new', $Path, '--size-gb', [string][math]::Ceiling($SizeBytes / 1GB)) }
    Get-VHD -Path $Path
}

function Resize-VHD {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][uint64]$SizeBytes)
    if ($script:HyperVAvailable) { return Hyper-V\Resize-VHD @PSBoundParameters }
    $null = Invoke-GpuVMHcs @('vhd-resize', $Path, [string]$SizeBytes)
}

function Mount-VHD {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [switch]$NoDriveLetter, [switch]$ReadOnly, [switch]$Passthru)
    if ($script:HyperVAvailable) { return Hyper-V\Mount-VHD @PSBoundParameters }
    $splat = @{ ImagePath = $Path; NoDriveLetter = $NoDriveLetter; ErrorAction = 'Stop' }
    if ($ReadOnly) { $splat['Access'] = 'ReadOnly' }
    $image = Mount-DiskImage @splat
    if ($Passthru) { Get-VHD -Path $Path } else { $null = $image }
}

function Dismount-VHD {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ($script:HyperVAvailable) { return Hyper-V\Dismount-VHD @PSBoundParameters }
    $null = Dismount-DiskImage -ImagePath $Path -ErrorAction Stop
}

# Without Hyper-V the result is a dynamic disk that holds the whole chain (a differencing disk comes out standalone).
function Convert-VHD {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$DestinationPath, [string]$VHDType)
    if ($script:HyperVAvailable) { return Hyper-V\Convert-VHD @PSBoundParameters }
    $null = Invoke-GpuVMHcs @('vhd-convert', [IO.Path]::GetFullPath($Path), [IO.Path]::GetFullPath($DestinationPath))
}
