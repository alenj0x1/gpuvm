# Lab 038: where the hitches and the black tears in games come from (Cyberpunk in win-gpu, 15 nov. 2026: Moonlight's
# log showed 145 "Waiting for IDR frame" in bursts, each after "Video decode unit queue overflow" on the HOST, and
# Sunshine's host processing latency up to 270 ms; the VM paged up to 2 GB).
# Hypotheses, as variants interleaved in rounds (data in $Variants):
#   base      8 vCPUs, stream at the monitor's rate (180)        today's setting
#   cpu6      6 vCPUs: 6 host threads stay free for Moonlight     host CPU starvation -> decode queue overflow
#   fps120    stream at 120 FPS                                    encode/decode load
#   nostream  no Moonlight: the game alone in the VM               how much the stream itself costs
# Load: GTA V's own benchmark (-benchmark), identical every pass. Per sample:
#   VM    PresentMon 2.6 on GTA5.exe (frame time, 1 % low, frames over 50 ms), GTA's own result file, page file peak
#   host  Moonlight's log (decode-queue overflows, IDR waits, host processing latency, network drops), host CPU and
#         Moonlight's CPU, available memory, person's input (samples with input are flagged)
# Takes the screen (~45 min). Run elevated:  pwsh -File labs/038-game-stutter/run.ps1
param(
    [string]$Name = 'win-gpu',
    [int]$Rounds = 2,
    [string[]]$Variants = @('base', 'cpu6', 'fps120', 'nostream'),
    [int]$MaxSampleSec = 600,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Import-Module (Join-Path $repo 'src\GpuVM\GpuVM.psd1') -Force -DisableNameChecking
$m = Get-Module GpuVM
$run = Join-Path $PSScriptRoot "out\$(Get-Date -Format 'yyyyMMdd-HHmmss')"; New-Item -ItemType Directory -Force $run | Out-Null
function Say([string]$t) { $l = "[$(Get-Date -Format HH:mm:ss)] $t"; Write-Host $l; Add-Content "$run\log.txt" $l }

$defs = @{
    base     = @{ Cpu = 8; Fps = 0; Stream = $true }
    cpu6     = @{ Cpu = 6; Fps = 0; Stream = $true }
    fps120   = @{ Cpu = 8; Fps = 120; Stream = $true }
    nostream = @{ Cpu = 8; Fps = 0; Stream = $false }
}
if (-not ('GpuVMLab038' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class GpuVMLab038 {
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO i);
    public static uint LastInput() { var i = new LASTINPUTINFO(); i.cbSize = 8; GetLastInputInfo(ref i); return i.dwTime; }
}
'@
}

$state = & $m { param($n) Get-GpuVMState -Name $n } $Name
$cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
$originalCpu = (Get-VMProcessor -VMName $Name).Count
$moonlight = Join-Path $env:ProgramFiles 'Moonlight Game Streaming\Moonlight.exe'
$steamArgs = '-applaunch 271590 -benchmark -benchmarkframetimes -benchmarkiterations 1'
$script:ses = $null

function Guest([scriptblock]$Block, [object[]]$Arguments = @()) {
    if (-not $script:ses -or $script:ses.State -ne 'Opened') {
        if ($script:ses) { Remove-PSSession $script:ses -ErrorAction SilentlyContinue }
        $script:ses = New-PSSession -VMName $Name -Credential $cred
    }
    Invoke-Command -Session $script:ses -ScriptBlock $Block -ArgumentList $Arguments
}

# Runs a command line in the signed-in user's desktop session (Steam and the game live there).
function Invoke-InUserSession([string]$Exe, [string]$Arguments) {
    Guest {
        param($exe, $a)
        $act = New-ScheduledTaskAction -Execute $exe -Argument $a
        Register-ScheduledTask -TaskName 'GpuVM-Lab038' -Action $act -Principal (New-ScheduledTaskPrincipal -UserId 'gpuvm' -LogonType Interactive -RunLevel Limited) -Force | Out-Null
        Start-ScheduledTask 'GpuVM-Lab038'; Start-Sleep 2; Unregister-ScheduledTask 'GpuVM-Lab038' -Confirm:$false
    } @($Exe, $Arguments)
}

function Wait-Guest([int]$TimeoutSec = 300) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if ((Get-VM $Name).State -ne 'Running') { throw "La VM '$Name' se apagó." }
        $ok = try { Guest { [bool](Get-Process steam, explorer -ErrorAction SilentlyContinue | Where-Object SessionId -gt 0) } } catch { $script:ses = $null; $false }
        if ($ok) { return [int]$sw.Elapsed.TotalSeconds }
        Start-Sleep 3
    }
    throw 'La VM no tuvo escritorio con Steam a tiempo.'
}

function Set-Cpu([int]$Count) {
    if ((Get-VMProcessor -VMName $Name).Count -eq $Count) { return }
    Say "VM a $Count hilos (reinicio)"
    Stop-VM -Name $Name
    Set-VMProcessor -VMName $Name -Count $Count
    Start-VM -Name $Name
    $script:ses = $null
    Say "  escritorio listo en $(Wait-Guest) s"
    Start-Sleep 30   # Steam and Sunshine settle after sign-in
}

function Stop-Game {
    Guest { Get-Process GTA5, PlayGTAV, GTAVLauncher -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } | Out-Null
}

function Close-Stream([string]$Address) {
    if (Get-Process Moonlight -ErrorAction SilentlyContinue) {
        # "quit" ends the session in Sunshine too (closing the window would leave it alive, lab 037).
        Start-Process $moonlight -ArgumentList 'quit', $Address -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ((Get-Process Moonlight -ErrorAction SilentlyContinue) -and $sw.Elapsed.TotalSeconds -lt 20) { Start-Sleep 1 }
        Get-Process Moonlight -ErrorAction SilentlyContinue | Stop-Process -Force
    }
}

function Read-MoonlightLog([string]$Path) {
    $t = Get-Content $Path
    $stats = ($t | Select-String 'Host processing latency min/max/average: ([\d.]+)/([\d.]+)/([\d.]+)' | Select-Object -Last 1)
    $drop = ($t | Select-String 'Frames dropped by your network connection: ([\d.]+)%' | Select-Object -Last 1)
    $rate = ($t | Select-String 'Incoming frame rate from network: ([\d.]+)' | Select-Object -Last 1)
    [ordered]@{
        decodeQueueOverflows = @($t | Select-String 'Video decode unit queue overflow').Count
        idrWaits             = @($t | Select-String 'Waiting for IDR frame').Count
        idrBursts            = @($t | Select-String 'Waiting for IDR frame' | ForEach-Object { $_.Line.Substring(0, 8) } | Select-Object -Unique).Count
        hostLatencyMaxMs     = if ($stats) { [double]$stats.Matches[0].Groups[2].Value } else { $null }
        hostLatencyAvgMs     = if ($stats) { [double]$stats.Matches[0].Groups[3].Value } else { $null }
        networkDropPct       = if ($drop) { [double]$drop.Matches[0].Groups[1].Value } else { $null }
        streamFps            = if ($rate) { [double]$rate.Matches[0].Groups[1].Value } else { $null }
    }
}

function Summarize-Frames([object[]]$Rows) {
    $col = @('FrameTime', 'MsBetweenPresents') | Where-Object { $Rows.Count -and $Rows[0].PSObject.Properties.Name -contains $_ } | Select-Object -First 1
    if (-not $col) { return $null }
    $ft = @($Rows | ForEach-Object { [double]$_.$col } | Where-Object { $_ -gt 0 } | Sort-Object)
    if ($ft.Count -lt 100) { return $null }
    $total = ($ft | Measure-Object -Sum).Sum
    $worst = $ft[[int][math]::Floor($ft.Count * 0.99)..($ft.Count - 1)]
    [ordered]@{
        frames      = $ft.Count
        avgFps      = [math]::Round($ft.Count / ($total / 1000), 1)
        low1Fps     = [math]::Round(1000 / (($worst | Measure-Object -Average).Average), 1)
        p99Ms       = [math]::Round($ft[[int][math]::Floor($ft.Count * 0.99)], 1)
        maxMs       = [math]::Round($ft[-1], 1)
        over50ms    = @($ft | Where-Object { $_ -gt 50 }).Count
        over100ms   = @($ft | Where-Object { $_ -gt 100 }).Count
        column      = $col
    }
}

# ---- Preflight
if ((Get-VM $Name).State -ne 'Running') { Say 'Encendiendo la VM'; Start-VM $Name }
Say "Escritorio de la VM listo ($(Wait-Guest) s)"
$address = (& $m { param($n) Get-GpuVMEndpoint -Name $n -TimeoutSec 120 } $Name).Address
Say "VM en $address; hilos originales $originalCpu"
$pre = Guest {
    [ordered]@{
        presentMon = Test-Path C:\GpuVMLab\PresentMon.exe
        gta        = Test-Path 'C:\Program Files (x86)\Steam\steamapps\common\Grand Theft Auto V\GTA5.exe'
        gpu        = (Get-CimInstance Win32_VideoController | Where-Object Name -match 'NVIDIA' | Select-Object -First 1).Status
        steamBusy  = [bool](Get-ChildItem 'C:\Program Files (x86)\Steam\steamapps\downloading' -Directory -ErrorAction SilentlyContinue)
    }
}
Say "Preflight: $($pre | ConvertTo-Json -Compress)"
if (-not $pre.presentMon -or -not $pre.gta) { throw 'Falta PresentMon o GTA V en la VM.' }
if ($pre.gpu -ne 'OK') { throw "La GPU de la VM no está lista ($($pre.gpu))." }
if ($pre.steamBusy) { Say 'AVISO: Steam sigue descargando algo; esas muestras llevan la marca downloading.' }
if ($DryRun) { Say 'DryRun: preflight OK'; return }

$results = [System.Collections.Generic.List[object]]::new()
try {
    for ($r = 1; $r -le $Rounds; $r++) {
        foreach ($v in $Variants) {
            $d = $defs[$v]
            $tag = "r$r-$v"
            Say "== $tag ($($d | ConvertTo-Json -Compress))"
            Stop-Game; Close-Stream $address
            Set-Cpu $d.Cpu
            Start-Sleep (Get-Random -Minimum 5 -Maximum 15)
            $sample = [ordered]@{ tag = $tag; variant = $v; round = $r; startedAt = (Get-Date).ToString('o'); cpu = $d.Cpu; fps = $d.Fps; stream = $d.Stream }
            $mlLog = $null
            if ($d.Stream) {
                $before = Get-Date
                $connect = @{ Name = $Name }; if ($d.Fps) { $connect['Fps'] = $d.Fps }
                Connect-GpuVM @connect 6>$null | Out-Null
                $sw = [Diagnostics.Stopwatch]::StartNew()
                while (-not (Get-Process Moonlight -ErrorAction SilentlyContinue) -and $sw.Elapsed.TotalSeconds -lt 60) { Start-Sleep 1 }
                Start-Sleep 10
                $mlLog = Get-ChildItem "$env:LOCALAPPDATA\Temp\Moonlight-*.log" | Where-Object LastWriteTime -gt $before | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if (-not $mlLog) { $mlLog = Get-ChildItem "$env:TEMP\Moonlight-*.log" | Where-Object LastWriteTime -gt $before | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
                Say "  Moonlight abierto, log $($mlLog.Name)"
            }
            $since = Guest { Get-Date }
            Invoke-InUserSession 'C:\Program Files (x86)\Steam\steam.exe' $steamArgs
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Guest { [bool](Get-Process GTA5 -ErrorAction SilentlyContinue) }) -and $sw.Elapsed.TotalSeconds -lt 240) { Start-Sleep 3 }
            if (-not (Guest { [bool](Get-Process GTA5 -ErrorAction SilentlyContinue) })) { Say '  GTA V no arrancó; muestra descartada'; $sample['discarded'] = 'gta-not-started'; $results.Add($sample); continue }
            $sample['gtaStartSec'] = [int]$sw.Elapsed.TotalSeconds
            $csv = "C:\GpuVMLab\pm-$tag.csv"
            Guest { param($c, $t) Start-Process C:\GpuVMLab\PresentMon.exe -ArgumentList '--process_name', 'GTA5.exe', '--output_file', $c, '--timed', $t, '--terminate_after_timed', '--no_console_stats', '--stop_existing_session', '--session_name', 'GpuVMLab038' -WindowStyle Hidden } @($csv, $MaxSampleSec) | Out-Null
            Say "  GTA V en $($sample['gtaStartSec']) s; midiendo hasta que termine el benchmark"
            $hostCpu = [System.Collections.Generic.List[double]]::new(); $mlCpu = [System.Collections.Generic.List[double]]::new(); $avail = [System.Collections.Generic.List[double]]::new()
            $input0 = [GpuVMLab038]::LastInput(); $touched = 0
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $prevMl = (Get-Process Moonlight -ErrorAction SilentlyContinue | Measure-Object CPU -Sum).Sum; $prevT = $sw.Elapsed.TotalSeconds
            while ($sw.Elapsed.TotalSeconds -lt $MaxSampleSec) {
                Start-Sleep 5
                $hostCpu.Add((Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime)
                $avail.Add((Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory).AvailableMBytes)
                $nowMl = (Get-Process Moonlight -ErrorAction SilentlyContinue | Measure-Object CPU -Sum).Sum; $nowT = $sw.Elapsed.TotalSeconds
                if ($null -ne $nowMl -and $null -ne $prevMl) { $mlCpu.Add(($nowMl - $prevMl) / ($nowT - $prevT) / [Environment]::ProcessorCount * 100) }
                $prevMl = $nowMl; $prevT = $nowT
                $li = [GpuVMLab038]::LastInput(); if ($li -ne $input0) { $touched++; $input0 = $li }
                if (-not (Guest { [bool](Get-Process GTA5 -ErrorAction SilentlyContinue) })) { break }
            }
            $sample['seconds'] = [int]$sw.Elapsed.TotalSeconds
            $sample['personInput'] = $touched
            $sample['hostCpuAvg'] = [math]::Round(($hostCpu | Measure-Object -Average).Average, 1)
            $sample['hostCpuMax'] = [math]::Round(($hostCpu | Measure-Object -Maximum).Maximum, 1)
            $sample['moonlightCpuAvg'] = if ($mlCpu.Count) { [math]::Round(($mlCpu | Measure-Object -Average).Average, 1) } else { $null }
            $sample['hostAvailMinMB'] = ($avail | Measure-Object -Minimum).Minimum
            Stop-Game
            Start-Sleep 3
            $g = Guest {
                param($c, $since)
                Get-Process PresentMon -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep 2
                $bench = Get-ChildItem "$env:USERPROFILE\..\gpuvm\Documents\Rockstar Games\GTA V\Benchmarks\*.txt", 'C:\Users\gpuvm\Documents\Rockstar Games\GTA V\Benchmarks\*.txt' -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                $pf = Get-CimInstance Win32_PageFileUsage | Select-Object -First 1
                [ordered]@{
                    csv = if (Test-Path $c) { Get-Content $c -Raw } else { $null }
                    bench = if ($bench) { Get-Content $bench.FullName -Raw } else { $null }
                    pageFilePeakMB = $pf.PeakUsage
                    sunshine = (Get-Content 'C:\Program Files\Sunshine\config\sunshine.log' -Tail 400 -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\[(.{19})' -and [datetime]$Matches[1] -gt $since }) -join "`n"
                }
            } @($csv, $since)
            if ($g.csv) { Set-Content "$run\$tag-presentmon.csv" $g.csv; $sample['frames'] = Summarize-Frames ($g.csv | ConvertFrom-Csv) }
            if ($g.bench) { Set-Content "$run\$tag-gta-benchmark.txt" $g.bench }
            if ($g.sunshine) { Set-Content "$run\$tag-sunshine.log" $g.sunshine }
            $sample['vmPageFilePeakMB'] = $g.pageFilePeakMB
            if ($d.Stream) {
                Close-Stream $address
                if ($mlLog) { Copy-Item $mlLog.FullName "$run\$tag-moonlight.log"; $sample['moonlight'] = Read-MoonlightLog "$run\$tag-moonlight.log" }
            }
            $results.Add($sample)
            Say "  $($sample | ConvertTo-Json -Compress -Depth 4)"
            $results | ConvertTo-Json -Depth 5 | Set-Content "$run\results.json"
        }
    }
}
finally {
    try { Stop-Game } catch {}
    Close-Stream $address
    if ((Get-VMProcessor -VMName $Name).Count -ne $originalCpu) { Say "Volviendo a $originalCpu hilos"; Stop-VM -Name $Name; Set-VMProcessor -VMName $Name -Count $originalCpu; Start-VM -Name $Name }
    try { Guest { Remove-Item C:\GpuVMLab\pm-*.csv -ErrorAction SilentlyContinue } } catch {}
    if ($script:ses) { Remove-PSSession $script:ses -ErrorAction SilentlyContinue }
    $results | ConvertTo-Json -Depth 5 | Set-Content "$run\results.json"
    Say "Resultados en $run"
}
