<#
.SYNOPSIS
Lab 043: how to put files from this PC into a running VM, and from one VM into another through the host.
Methods (interleaved per round):
  psd     Copy-Item -ToSession over PowerShell Direct (what GpuVM uses for installers).
  gsi     Copy-VMFile (Hyper-V Guest Service Interface), one call per file. Turned on for the run, restored after.
  stream  Our own chunked copy over PowerShell Direct: byte[] chunks written to a FileStream kept in the session.
  disk    Shared disk: Import-GpuVMSharedDisk on the host, hot-attach, robocopy inside the guest.
  relay   VM -> VM path: chunks read in one guest session and written by another (here both in the same VM),
          never touching the host's disk.
Data: random (incompressible) files. Writes only to C:\GpuVM-lab-043 on the host and C:\GpuVM-lab in the guest;
both are deleted at the end.
#>
param(
    [string]$VMName = 'win-gpu',
    [string[]]$Methods = @('psd', 'gsi', 'stream', 'tar', 'disk', 'relay'),
    [string[]]$Sets = @('1mb', 'small', '1gb', '10gb'),
    [int]$Rounds = 2,
    [hashtable]$Reps = @{ '1mb' = 5; 'small' = 1; '100mb' = 2; '1gb' = 1; '10gb' = 1 },
    [int]$ChunkMB = 4,
    [string]$Owner = 'files-clipboard',
    [switch]$KeepData
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lock.ps1')
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null
$results = Join-Path $out "results-$(Get-Date -Format yyyyMMdd-HHmmss).jsonl"
$hostRoot = 'C:\GpuVM-lab-043'
$guestRoot = 'C:\GpuVM-lab'

Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
$module = Get-Module GpuVM
$state = & $module { param($n) Get-GpuVMState -Name $n } $VMName
$cred = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state
if ((Get-VM $VMName).State -ne 'Running') { throw "$VMName está apagada." }

# ---------------------------------------------------------------- data
function New-RandomFile([string]$Path, [int64]$Bytes) {
    if ((Test-Path $Path) -and (Get-Item $Path).Length -eq $Bytes) { return }
    $block = [byte[]]::new([math]::Min($Bytes, 64MB))
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($block)
    $fs = [IO.File]::Create($Path)
    try {
        $left = $Bytes; $n = 0
        while ($left -gt 0) {
            # A different header per block: no two blocks are equal (no dedup, no compression gain).
            [BitConverter]::GetBytes([int64]$n++).CopyTo($block, 0)
            $len = [int][math]::Min($left, $block.Length)
            $fs.Write($block, 0, $len); $left -= $len
        }
    }
    finally { $fs.Dispose() }
}
function Get-Set([string]$Set) {
    $dir = Join-Path $hostRoot "data\$Set"
    New-Item -ItemType Directory -Force $dir | Out-Null
    switch ($Set) {
        '1mb' { New-RandomFile (Join-Path $dir 'a.bin') 1MB }
        '100mb' { New-RandomFile (Join-Path $dir 'a.bin') 100MB }
        '1gb' { New-RandomFile (Join-Path $dir 'a.bin') 1GB }
        '10gb' { New-RandomFile (Join-Path $dir 'a.bin') 10GB }
        'small' {
            # 2000 files of 4-64 KB in 20 folders (a source tree, a photo folder).
            if (@(Get-ChildItem $dir -Recurse -File).Count -ne 2000) {
                $rng = [Random]::new(43)
                foreach ($f in 0..19) {
                    $sub = Join-Path $dir "d$f"; New-Item -ItemType Directory -Force $sub | Out-Null
                    foreach ($i in 0..99) { $b = [byte[]]::new($rng.Next(4KB, 64KB)); $rng.NextBytes($b); [IO.File]::WriteAllBytes((Join-Path $sub "f$i.bin"), $b) }
                }
            }
        }
    }
    $files = @(Get-ChildItem $dir -Recurse -File)
    [pscustomobject]@{ Dir = $dir; Files = $files; Bytes = [int64]($files | Measure-Object Length -Sum).Sum; Count = $files.Count }
}

# ---------------------------------------------------------------- methods (each copies $Data.Dir into $Dest in the guest)
function Copy-Psd($s, $Data, $Dest) {
    Invoke-Command -Session $s { param($d) New-Item -ItemType Directory -Force $d | Out-Null } -ArgumentList $Dest
    Copy-Item -Path (Join-Path $Data.Dir '*') -Destination $Dest -ToSession $s -Recurse -Force
}
function Copy-Gsi($s, $Data, $Dest) {
    foreach ($f in $Data.Files) {
        $rel = $f.FullName.Substring($Data.Dir.Length + 1)
        Copy-VMFile -Name $VMName -SourcePath $f.FullName -DestinationPath (Join-Path $Dest $rel) -FileSource Host -CreateFullPath -Force
    }
}
function Copy-Stream($s, $Data, $Dest) {
    $chunk = [byte[]]::new($ChunkMB * 1MB)
    foreach ($f in $Data.Files) {
        $rel = $f.FullName.Substring($Data.Dir.Length + 1)
        Invoke-Command -Session $s { param($p) New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null; $global:lab = [IO.File]::Create($p) } -ArgumentList (Join-Path $Dest $rel)
        $src = [IO.File]::OpenRead($f.FullName)
        try {
            while (($n = $src.Read($chunk, 0, $chunk.Length)) -gt 0) {
                $piece = if ($n -eq $chunk.Length) { $chunk } else { $p = [byte[]]::new($n); [Array]::Copy($chunk, $p, $n); $p }
                Invoke-Command -Session $s { param([byte[]]$b) $global:lab.Write($b, 0, $b.Length) } -ArgumentList (, [byte[]]$piece)
            }
        }
        finally { $src.Dispose(); Invoke-Command -Session $s { $global:lab.Dispose() } }
    }
}
function Copy-Disk($s, $Data, $Dest) {
    $disk = 'lab043'
    $att = Get-VMHardDiskDrive -VMName $VMName | Where-Object Path -like '*lab043*'
    if ($att) { Disconnect-GpuVMSharedDisk -Name $disk | Out-Null }
    Import-GpuVMSharedDisk -Name $disk -Path $Data.Dir | Out-Null
    $letter = (Connect-GpuVMSharedDisk -Name $disk -VMName $VMName)['letter']
    $leaf = Split-Path $Data.Dir -Leaf
    $code = Invoke-Command -Session $s { param($l, $leaf, $d)
        robocopy "$($l):\$leaf" $d /E /MT:8 /R:1 /W:1 /NP /NFL /NDL | Out-Null; $LASTEXITCODE } -ArgumentList $letter, $leaf, $Dest
    if ($code -ge 8) { throw "robocopy en la VM: $code" }
    # Leave the disk clean for the next sample (the copy on it is part of this method's cost, not the next one's).
    Invoke-Command -Session $s { param($l, $leaf) Remove-Item "$($l):\$leaf" -Recurse -Force } -ArgumentList $letter, $leaf
}
# VM -> VM: read in session A, write in session B. Source is what psd left in C:\GpuVM-lab\src-<set>.
function Copy-Relay($s, $Data, $Dest, $s2, $Source) {
    $files = Invoke-Command -Session $s { param($d) Get-ChildItem $d -Recurse -File | ForEach-Object { @{ p = $_.FullName.Substring($d.Length + 1); n = $_.Length } } } -ArgumentList $Source
    foreach ($f in $files) {
        Invoke-Command -Session $s { param($p) $global:src = [IO.File]::OpenRead($p); $global:buf = [byte[]]::new($using:ChunkMB * 1MB) } -ArgumentList (Join-Path $Source $f.p)
        Invoke-Command -Session $s2 { param($p) New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null; $global:dst = [IO.File]::Create($p) } -ArgumentList (Join-Path $Dest $f.p)
        try {
            while ($true) {
                $piece = Invoke-Command -Session $s { $n = $global:src.Read($global:buf, 0, $global:buf.Length); if ($n -eq 0) { , [byte[]]@() } elseif ($n -eq $global:buf.Length) { , $global:buf } else { $p = [byte[]]::new($n); [Array]::Copy($global:buf, $p, $n); , $p } }
                if (-not $piece -or $piece.Length -eq 0) { break }
                Invoke-Command -Session $s2 { param([byte[]]$b) $global:dst.Write($b, 0, $b.Length) } -ArgumentList (, [byte[]]$piece)
            }
        }
        finally { Invoke-Command -Session $s { $global:src.Dispose() }; Invoke-Command -Session $s2 { $global:dst.Dispose() } }
    }
}

# Folders as one stream: tar on the host (stdout) -> chunks -> tar in the guest (stdin). One round trip per chunk,
# not per file.
function Copy-Tar($s, $Data, $Dest) {
    Invoke-Command -Session $s { param($d)
        New-Item -ItemType Directory -Force $d | Out-Null
        $psi = [Diagnostics.ProcessStartInfo]::new("$env:SystemRoot\System32\tar.exe", '-x -f - -C "' + $d + '"')
        $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardError = $true
        $global:tarx = [Diagnostics.Process]::Start($psi)
    } -ArgumentList $Dest
    $psi = [Diagnostics.ProcessStartInfo]::new("$env:SystemRoot\System32\tar.exe", '-c -f - -C "' + $Data.Dir + '" .')
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true
    $p = [Diagnostics.Process]::Start($psi)
    $chunk = [byte[]]::new($ChunkMB * 1MB)
    try {
        $stdout = $p.StandardOutput.BaseStream
        while ($true) {
            # Fill the whole chunk (a pipe returns short reads).
            $n = 0
            while ($n -lt $chunk.Length -and ($r = $stdout.Read($chunk, $n, $chunk.Length - $n)) -gt 0) { $n += $r }
            if ($n -eq 0) { break }
            $piece = if ($n -eq $chunk.Length) { $chunk } else { $q = [byte[]]::new($n); [Array]::Copy($chunk, $q, $n); $q }
            Invoke-Command -Session $s { param([byte[]]$b) $global:tarx.StandardInput.BaseStream.Write($b, 0, $b.Length) } -ArgumentList (, [byte[]]$piece)
            if ($n -lt $chunk.Length) { break }
        }
    }
    finally {
        $p.WaitForExit()
        $code = Invoke-Command -Session $s { $global:tarx.StandardInput.Close(); $global:tarx.WaitForExit(); $global:tarx.ExitCode }
    }
    if ($code -ne 0) { throw "tar en la VM: $code" }
}

function Measure-Guest($s, $Dest) {
    Invoke-Command -Session $s { param($d) $f = @(Get-ChildItem $d -Recurse -File -ErrorAction SilentlyContinue); @{ count = $f.Count; bytes = [int64]($f | Measure-Object Length -Sum).Sum } } -ArgumentList $Dest
}

# Another session's job on C: (a VHD compact wrote 1.7 GB/s) makes every copy look 10x slower: wait for the disk to
# be quiet (< 50 MB/s in 2 s) before each sample, at most 5 min, and record what it was.
function Wait-QuietDisk {
    $deadline = (Get-Date).AddMinutes(5)
    while ($true) {
        $mbps = [math]::Round((Get-Counter '\PhysicalDisk(_Total)\Disk Bytes/sec' -SampleInterval 2).CounterSamples[0].CookedValue / 1MB, 1)
        if ($mbps -lt 50 -or (Get-Date) -gt $deadline) { return $mbps }
        Write-Host "Disco ocupado ($mbps MB/s), espero"
    }
}

# ---------------------------------------------------------------- run
$gsiBefore = (Get-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface').Enabled
$diskMade = $false
Enter-LabLock -Owner $Owner -Doing 'lab 043: copias PC -> VM (sin GPU, disco y CPU)'
$s = $null; $s2 = $null
try {
    if ('gsi' -in $Methods -and -not $gsiBefore) { Enable-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface'; Start-Sleep 5 }
    if ('disk' -in $Methods -and -not (Test-Path 'C:\GpuVM\.shared\lab043.vhdx')) {
        $max = [math]::Ceiling(((($Sets | ForEach-Object { (Get-Set $_).Bytes }) | Measure-Object -Maximum).Maximum) / 1GB) + 4
        New-GpuVMSharedDisk -Name lab043 -SizeGB ([math]::Max(8, $max)) -Purpose general -Confirm:$false | Out-Null; $diskMade = $true
    }
    $t = [Diagnostics.Stopwatch]::StartNew(); $s = New-PSSession -VMName $VMName -Credential $cred; $openMs = $t.ElapsedMilliseconds
    $s2 = New-PSSession -VMName $VMName -Credential $cred
    Write-Host "Sesión PowerShell Direct abierta en $openMs ms"
    foreach ($round in 1..$Rounds) {
        foreach ($set in $Sets) {
            $data = Get-Set $set
            $src = "$guestRoot\src-$set"
            if ('relay' -in $Methods -and -not (Invoke-Command -Session $s { param($p) Test-Path $p } -ArgumentList $src)) { Copy-Psd $s $data $src }
            $order = if ($round % 2) { $Methods } else { $Methods[($Methods.Count - 1)..0] }
            foreach ($method in $order) {
                foreach ($rep in 1..$Reps[$set]) {
                    $dest = "$guestRoot\$method-$set"
                    Invoke-Command -Session $s { param($d) Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } -ArgumentList $dest
                    Start-Sleep -Milliseconds (Get-Random -Minimum 200 -Maximum 900)
                    $quiet = Wait-QuietDisk
                    $row = [ordered]@{ diskMBpsBefore = $quiet; at = (Get-Date -Format o); round = $round; set = $set; method = $method; rep = $rep; bytes = $data.Bytes; files = $data.Count; chunkMB = $ChunkMB; ms = $null; ok = $false; error = $null }
                    $sw = [Diagnostics.Stopwatch]::StartNew()
                    try {
                        switch ($method) {
                            'psd' { Copy-Psd $s $data $dest }
                            'gsi' { Copy-Gsi $s $data $dest }
                            'stream' { Copy-Stream $s $data $dest }
                            'tar' { Copy-Tar $s $data $dest }
                            'disk' { Copy-Disk $s $data $dest }
                            'relay' { Copy-Relay $s $data $dest $s2 $src }
                        }
                        $row.ms = $sw.ElapsedMilliseconds
                        $got = Measure-Guest $s $dest
                        $row.ok = ($data.Count -gt 0 -and $got.count -eq $data.Count -and $got.bytes -eq $data.Bytes)
                        if (-not $row.ok) { $row.error = "en la VM: $($got.count) archivos, $($got.bytes) bytes" }
                    }
                    catch { $row.ms = $sw.ElapsedMilliseconds; $row.error = "$_" }
                    finally {
                        $row | ConvertTo-Json -Compress | Add-Content $results
                        $mbps = if ($row.ms) { [math]::Round($data.Bytes / 1MB / ($row.ms / 1000), 1) } else { 0 }
                        Write-Host ("r{0} {1,-5} {2,-6} {3,8} ms {4,7} MB/s {5}" -f $round, $set, $method, $row.ms, $mbps, $(if ($row.ok) { 'ok' } else { $row.error }))
                    }
                }
                Invoke-Command -Session $s { param($d) Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } -ArgumentList "$guestRoot\$method-$set"
            }
        }
    }
}
finally {
    if ($s) { Invoke-Command -Session $s { param($d) Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } -ArgumentList $guestRoot -ErrorAction SilentlyContinue }
    if ($s) { Remove-PSSession $s }; if ($s2) { Remove-PSSession $s2 }
    if (Test-Path 'C:\GpuVM\.shared\lab043.vhdx') {
        try { Disconnect-GpuVMSharedDisk -Name lab043 | Out-Null } catch { Write-Warning "$_" }
        if ($diskMade -or -not $KeepData) { Remove-GpuVMSharedDisk -Name lab043 -Confirm:$false | Out-Null }
    }
    if ('gsi' -in $Methods -and -not $gsiBefore) { Disable-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface' }
    if (-not $KeepData) { Remove-Item $hostRoot -Recurse -Force -ErrorAction SilentlyContinue }
    Exit-LabLock -Owner $Owner
    Write-Host "Resultados: $results"
}
