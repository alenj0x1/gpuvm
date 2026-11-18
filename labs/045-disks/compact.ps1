# Lab 045, part 3: lighter templates. A template is Convert-VHD of the VM's disk: it keeps every block the guest
# ever wrote, deleted files included. Candidates shrink the COPY (never the source) after Convert-VHD:
#   convert       baseline: Convert-VHD to a dynamic disk
#   ro-full       + mount read-only, Optimize-VHD -Mode Full (Windows reads NTFS's free space map)
#   retrim-full   + mount without a letter, Optimize-Volume -ReTrim on its NTFS volumes, dismount, Optimize-VHD -Mode Full
#   retrim-quick  the same TRIM, then Optimize-VHD -Mode Quick with the disk not mounted (run 2)
#   ro-retrim-quick  mount read-only, Optimize-VHD -Mode Retrim, dismount, Optimize-VHD -Mode Quick (run 3; the
#                    guest's file system is never mounted for writing)
# Source: a differencing disk on a Windows base where -WasteGB of random data was written and deleted (space the
# guest "used once"), plus -KeepGB kept. Interleaved rounds. Writes out/compact-*.json. Elevated PowerShell 7.
param(
    # A never-booted Windows base if there is one, else lab045-tpl's disk (any Windows disk works as a parent).
    [string]$Parent = $(@(Get-ChildItem 'C:\GpuVM\.bases\*\base.vhdx', 'C:\GpuVM\.templates\lab045-tpl\lab045-tpl.vhdx' -ErrorAction SilentlyContinue)[0].FullName),
    [int]$WasteGB = 8,
    [int]$KeepGB = 2,
    [int]$Rounds = 2,
    [string[]]$Variants = @('convert', 'module'),
    [string]$Work = 'C:\GpuVM\lab045-compact'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out, $Work | Out-Null
$rows = [System.Collections.Generic.List[object]]::new()

function Fill($root, $file, $gb) {
    $buf = [byte[]]::new(16MB); $rng = [Random]::new(45)
    $fs = [IO.File]::Create((Join-Path $root $file))
    try { for ($i = 0; $i -lt $gb * 64; $i++) { $rng.NextBytes($buf); $fs.Write($buf, 0, $buf.Length) } } finally { $fs.Dispose() }
}

$source = Join-Path $Work 'source.vhdx'
try {
    New-VHD -Path $source -ParentPath $Parent -Differencing | Out-Null
    & (Get-Module GpuVM) {
        param($source, $WasteGB, $KeepGB)
        Invoke-WithMountedWindows -Path $source -ScriptBlock {
            param($r)
            function Fill($root, $file, $gb) {
                $buf = [byte[]]::new(16MB); $rng = [Random]::new(45)
                $fs = [IO.File]::Create((Join-Path $root $file))
                try { for ($i = 0; $i -lt $gb * 64; $i++) { $rng.NextBytes($buf); $fs.Write($buf, 0, $buf.Length) } } finally { $fs.Dispose() }
            }
            Fill $r 'lab045-waste.bin' $WasteGB
            Fill $r 'lab045-keep.bin' $KeepGB
            Remove-Item (Join-Path $r 'lab045-waste.bin')
        }
    } $source $WasteGB $KeepGB
    $srcBytes = (Get-Item $source).Length + (Get-Item $Parent).Length
    Write-Host "source chain: $([math]::Round($srcBytes / 1GB, 2)) GB"

    for ($round = 1; $round -le $Rounds; $round++) {
        $order = if ($round % 2) { $Variants } else { $Variants[($Variants.Count - 1)..0] }
        foreach ($variant in $order) {
            $target = Join-Path $Work "$variant.vhdx"
            if (Test-Path $target) { Remove-Item $target -Force }
            $t = [ordered]@{ round = $round; variant = $variant }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            Convert-VHD -Path $source -DestinationPath $target -VHDType Dynamic
            $t.convertS = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            $t.afterConvertGB = [math]::Round((Get-Item $target).Length / 1GB, 2)
            if ($variant -like 'retrim-*') {
                $s2 = [Diagnostics.Stopwatch]::StartNew()
                Mount-VHD -Path $target -NoDriveLetter
                try {
                    foreach ($part in @(Get-Partition -DiskNumber (Get-VHD $target).DiskNumber)) {
                        $vol = $part | Get-Volume -ErrorAction SilentlyContinue
                        if ($vol -and $vol.FileSystemType -eq 'NTFS') { $vol | Optimize-Volume -ReTrim }
                    }
                }
                finally { Dismount-VHD -Path $target }
                $t.retrimS = [math]::Round($s2.Elapsed.TotalSeconds, 1)
            }
            if ($variant -eq 'retrim-quick') { $s3 = [Diagnostics.Stopwatch]::StartNew(); Optimize-VHD -Path $target -Mode Quick; $t.optimizeS = [math]::Round($s3.Elapsed.TotalSeconds, 1) }
            if ($variant -eq 'module') {
                $s3 = [Diagnostics.Stopwatch]::StartNew()
                & (Get-Module GpuVM) { param($p) Compress-GpuVMDiskCopy -Path $p } $target | Out-Null
                $t.optimizeS = [math]::Round($s3.Elapsed.TotalSeconds, 1)
            }
            if ($variant -eq 'ro-retrim-quick') {
                $s3 = [Diagnostics.Stopwatch]::StartNew()
                Mount-VHD -Path $target -ReadOnly -NoDriveLetter
                try { Optimize-VHD -Path $target -Mode Retrim } finally { Dismount-VHD -Path $target }
                Optimize-VHD -Path $target -Mode Quick
                $t.optimizeS = [math]::Round($s3.Elapsed.TotalSeconds, 1)
            }
            if ($variant -in 'ro-full', 'retrim-full') {
                $s3 = [Diagnostics.Stopwatch]::StartNew()
                Mount-VHD -Path $target -ReadOnly -NoDriveLetter
                try { Optimize-VHD -Path $target -Mode Full } finally { Dismount-VHD -Path $target }
                $t.optimizeS = [math]::Round($s3.Elapsed.TotalSeconds, 1)
            }
            $t.totalS = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            $t.finalGB = [math]::Round((Get-Item $target).Length / 1GB, 2)
            # The copy must still hold the kept file and Windows.
            $t.intact = & (Get-Module GpuVM) {
                param($p)
                Invoke-WithMountedWindows -Path $p -ScriptBlock { param($r) (Test-Path (Join-Path $r 'lab045-keep.bin')) -and -not (Test-Path (Join-Path $r 'lab045-waste.bin')) }
            } $target
            $rows.Add([pscustomobject]$t)
            Write-Host ($t | ConvertTo-Json -Compress)
            Remove-Item $target -Force
        }
    }
}
finally {
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    [ordered]@{ wasteGB = $WasteGB; keepGB = $KeepGB; rows = $rows } | ConvertTo-Json -Depth 4 |
        Set-Content (Join-Path $out "compact-$(Get-Date -Format yyyyMMdd-HHmmss).json")
}
