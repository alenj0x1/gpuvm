# Convert-VHD keeps every block ever written. On the copy, mounted read-only: -Mode Retrim marks NTFS's free blocks,
# then -Mode Quick, dismounted, gives them back (TRIM from a writable mount and -Mode Full give back almost nothing).
function Compress-GpuVMDiskCopy {
    param([Parameter(Mandatory)][string]$Path)
    $before = (Get-Item -LiteralPath $Path).Length
    # Without Hyper-V there is no Optimize-VHD: the copy keeps its size.
    if (-not $script:HyperVAvailable) { return [int64]0 }
    Write-Step 'Giving back the space Windows no longer uses'
    Mount-VHD -Path $Path -ReadOnly -NoDriveLetter
    try { Optimize-VHD -Path $Path -Mode Retrim }
    finally { Dismount-VHD -Path $Path }
    Optimize-VHD -Path $Path -Mode Quick
    $after = (Get-Item -LiteralPath $Path).Length
    [math]::Max([int64]0, [int64]($before - $after))
}
