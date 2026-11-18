# Making a copy of a VM's disk (a template, an export) take only what Windows uses now. Convert-VHD keeps every
# block the guest ever wrote, deleted files included (lab 016: 159 GB from a 200 GB fixed disk).
# On the COPY (never the VM's own disk), mounted read-only: Optimize-VHD -Mode Retrim marks the blocks NTFS doesn't
# use as free, and -Mode Quick, with the disk dismounted, gives them back to the host. Lab 045: 8 GB written and
# deleted inside the guest came back whole (19.25 -> 11.29 GB) in 3.4 s; TRIM from a writable mount
# (Optimize-Volume -ReTrim) and Optimize-VHD -Mode Full gave back almost nothing. The guest's file system is never
# mounted for writing, so nothing the guest wrote is changed or opened by Explorer, the indexer or antivirus.
function Compress-GpuVMDiskCopy {
    param([Parameter(Mandatory)][string]$Path)
    $before = (Get-Item -LiteralPath $Path).Length
    Write-Step 'Liberando el espacio que Windows ya no usa'
    Mount-VHD -Path $Path -ReadOnly -NoDriveLetter
    try { Optimize-VHD -Path $Path -Mode Retrim }
    finally { Dismount-VHD -Path $Path }
    Optimize-VHD -Path $Path -Mode Quick
    $after = (Get-Item -LiteralPath $Path).Length
    [math]::Max([int64]0, [int64]($before - $after))
}
