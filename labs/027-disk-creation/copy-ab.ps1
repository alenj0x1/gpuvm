# Lab 027, part B: the copy alone. Copies a 3 GB file twice with each method (robocopy /J as in the first run, and
# GpuVM's paced copy), interleaved, while tools/host-probe/probe.ps1 times the host. No elevation needed.
#   pwsh -File labs/027-disk-creation/copy-ab.ps1
# Variants as data: "robocopy", or "name=start,max,min,slowMs,step" for the paced copy (MB/s and ms).
param([int]$SizeGB = 3, [int]$Rounds = 2, [int]$GapSec = 15,
    [string[]]$Variants = @('robocopy', 'pace400=200,400,25,40,10'))
$Variants = @($Variants | ForEach-Object { $_ -split ';' } | Where-Object { $_ })
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$out = Join-Path $PSScriptRoot "out\copy-ab-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$work = Join-Path $env:TEMP 'gpuvm-copy-ab'
New-Item -ItemType Directory -Force $out, $work | Out-Null
$m = Import-Module (Join-Path $repo 'src\GpuVM\GpuVM.psd1') -Force -PassThru
$src = Join-Path $work 'src\base.vhdx'
New-Item -ItemType Directory -Force (Split-Path $src) | Out-Null
if (-not (Test-Path $src) -or (Get-Item $src).Length -ne $SizeGB * 1GB) {
    $block = [byte[]]::new(64MB); [Random]::new(5).NextBytes($block)
    $f = [IO.File]::Create($src); try { for ($i = 0; $i -lt $SizeGB * 16; $i++) { $f.Write($block, 0, $block.Length) }; $f.Flush($true) } finally { $f.Dispose() }
    # The SSD is still absorbing the new file: the first variant would pay for it (it did, in the first runs).
    Start-Sleep -Seconds 90
}
$probeOut = Join-Path $out 'probe.jsonl'; $stop = Join-Path $out 'probe.stop'
$probe = Start-Process pwsh -ArgumentList '-NoProfile', '-File', (Join-Path $repo 'tools\host-probe\probe.ps1'), '-Out', $probeOut, '-StopFile', $stop -WindowStyle Hidden -PassThru
$phases = [System.Collections.Generic.List[object]]::new()
try {
    Start-Sleep -Seconds 5
    $t = Get-Date; Start-Sleep -Seconds 30; $phases.Add(@{ phase = 'idle'; a = $t; b = Get-Date })
    for ($r = 1; $r -le $Rounds; $r++) {
        # Odd rounds in order, even rounds reversed.
        $order = if ($r % 2) { $Variants } else { [array]::Reverse(($copy = @($Variants))); $copy }
        foreach ($variant in $order) {
            $method, $settings = $variant -split '='
            $dstDir = Join-Path $work "dst-$method"; Remove-Item -Recurse -Force $dstDir -ErrorAction SilentlyContinue; New-Item -ItemType Directory $dstDir | Out-Null
            $t = Get-Date
            if ($method -eq 'robocopy') { & robocopy (Split-Path $src) $dstDir base.vhdx /J /NP /NJH /NJS | Out-Null }
            else {
                $v = [double[]]($settings -split ',')
                [GpuVMPacedCopy]::StartRate = $v[0]; [GpuVMPacedCopy]::MaxRate = $v[1]; [GpuVMPacedCopy]::MinRate = $v[2]; [GpuVMPacedCopy]::SlowWriteMs = $v[3]; [GpuVMPacedCopy]::RateStep = $v[4]
                $stats = & $m { param($s, $d) Copy-PacedFile -Source $s -Destination $d } $src (Join-Path $dstDir 'base.vhdx')
                Write-Host ("$method-$r backoffs $($stats[2])")
            }
            $phases.Add(@{ phase = "$method-$r"; a = $t; b = Get-Date })
            Remove-Item -Recurse -Force $dstDir
            Start-Sleep -Seconds $GapSec
        }
    }
}
finally {
    New-Item -ItemType File -Force $stop | Out-Null; $probe.WaitForExit(10000) | Out-Null
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    $s = Get-Content $probeOut | ForEach-Object { $_ | ConvertFrom-Json }
    $rows = foreach ($p in $phases) {
        $in = @($s | Where-Object { $x = [datetime]$_.t; $x -ge $p.a -and $x -lt $p.b })
        $w = @($in.write | Sort-Object); $rd = @($in.read | Sort-Object)
        [pscustomobject]@{ phase = $p.phase; seconds = [math]::Round(($p.b - $p.a).TotalSeconds, 1); MBs = if ($p.phase -ne 'idle') { [math]::Round($SizeGB * 1024 / ($p.b - $p.a).TotalSeconds) }
            writeP50 = $w[[int]($w.Count * 0.5)]; writeP95 = $w[[int]($w.Count * 0.95)]; writeMax = $w[-1]; slowWrites = @($in | Where-Object write -gt 50).Count; n = $in.Count; readP95 = $rd[[int]($rd.Count * 0.95)] }
    }
    $rows | ConvertTo-Json | Set-Content (Join-Path $out 'summary.json')
    $rows | Format-Table -AutoSize | Out-String | Write-Host
}
