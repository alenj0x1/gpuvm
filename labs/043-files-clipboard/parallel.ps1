<#
.SYNOPSIS
Lab 043 (parallel): does PowerShell Direct go faster with several sessions writing parts of the same file at once?
One PowerShell Direct session tops out near 10-15 MB/s (serialization of byte[] in both ends), which is the cost of
keeping the copy on the channel GpuVM already uses. Writes C:\GpuVM-lab\par.bin in the guest; deleted after.
#>
param([string]$VMName = 'win-gpu', [int[]]$Sessions = @(1, 2, 4, 8), [int]$SizeMB = 512, [int]$ChunkMB = 4, [int]$Rounds = 2, [string]$Owner = 'files-clipboard')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lock.ps1')
Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
$m = Get-Module GpuVM
$cred = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $VMName
$out = Join-Path $PSScriptRoot 'out'; New-Item -ItemType Directory -Force $out | Out-Null
$results = Join-Path $out "parallel-$(Get-Date -Format yyyyMMdd-HHmmss).jsonl"
Enter-LabLock -Owner $Owner -Doing 'lab 043: sesiones paralelas de PowerShell Direct (CPU y disco)'
try {
    $open = @(1..([int]($Sessions | Measure-Object -Maximum).Maximum) | ForEach-Object { New-PSSession -VMName $VMName -Credential $cred })
    Invoke-Command -Session $open[0] { New-Item -ItemType Directory -Force C:\GpuVM-lab | Out-Null }
    $chunks = $SizeMB / $ChunkMB
    foreach ($round in 1..$Rounds) {
        foreach ($n in $Sessions) {
            Invoke-Command -Session $open[0] -ArgumentList ($SizeMB * 1MB) { param($len) $f = [IO.File]::Create('C:\GpuVM-lab\par.bin'); $f.SetLength($len); $f.Dispose() }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            # Each session writes every n-th chunk at its own offset.
            0..($n - 1) | ForEach-Object -ThrottleLimit $n -Parallel {
                $s = ($using:open)[$_]
                $chunk = [byte[]]::new($using:ChunkMB * 1MB)
                (New-Object Random $_).NextBytes($chunk)
                Invoke-Command -Session $s { $global:par = [IO.File]::Open('C:\GpuVM-lab\par.bin', 'Open', 'Write', 'ReadWrite') }
                for ($i = $_; $i -lt $using:chunks; $i += $using:n) {
                    Invoke-Command -Session $s -ArgumentList ([int64]$i * $chunk.Length), $chunk { param([int64]$at, [byte[]]$b) $null = $global:par.Seek($at, 'Begin'); $global:par.Write($b, 0, $b.Length) }
                }
                Invoke-Command -Session $s { $global:par.Dispose() }
            }
            $ms = $sw.ElapsedMilliseconds
            $row = [ordered]@{ round = $round; sessions = $n; mb = $SizeMB; chunkMB = $ChunkMB; ms = $ms; mbps = [math]::Round($SizeMB / ($ms / 1000), 1) }
            $row | ConvertTo-Json -Compress | Add-Content $results
            Write-Host ("r{0} {1} sesiones: {2} ms, {3} MB/s" -f $round, $n, $ms, $row.mbps)
        }
    }
}
finally {
    try { if ($open) { Invoke-Command -Session $open[0] { Remove-Item C:\GpuVM-lab -Recurse -Force -ErrorAction SilentlyContinue } -ErrorAction SilentlyContinue; $open | Remove-PSSession } }
    finally { Exit-LabLock -Owner $Owner }
}
