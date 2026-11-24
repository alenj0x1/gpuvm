# Lab 067: the HCS engine in the host service, end to end through `gpuvm-host hcs ...`: a machine made from a
# template, a probe written into its disk with the link-safe offline writer (Startup folder, no registry), started
# with the GPU and GpuVM's network, the probe's report read back, the machine deleted.
#   pwsh -NoProfile -File labs/067-hcs-engine/run.ps1 [-Gpu nvidia|intel|default] [-Exe <gpuvm-host.exe>]
# Needs an elevated shell. Takes C:\GpuVM\.lab-lock for the whole run and leaves nothing behind.
param([ValidateSet('nvidia', 'intel', 'default')][string]$Gpu = 'nvidia', [string]$Template = 'normal-tpl', [int]$TimeoutSec = 480,
    [switch]$Keep, [string]$Exe = (Join-Path $PSScriptRoot '..\..\app\host\target\debug\gpuvm-host.exe'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = $PSScriptRoot
$lab065 = Join-Path $here '..\065-hcs-backend'
$root = 'C:\GpuVM\.lab067'
$name = 'm067'
$lock = 'C:\GpuVM\.lab-lock'
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$Gpu"
$outDir = Join-Path $here 'out'; $null = New-Item -ItemType Directory -Force $outDir
$service = [guid]'0651ab67-7c1e-4b0a-9a65-065065065067'
$res = [ordered]@{ runId = $runId; gpu = $Gpu; steps = [ordered]@{} }
$sw = [Diagnostics.Stopwatch]::StartNew()
function Log([string]$m) { Write-Host ("[{0,6:n1}s] {1}" -f $sw.Elapsed.TotalSeconds, $m) }
function Hcs([string[]]$Arguments) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    $line = & $Exe hcs @Arguments | Select-Object -Last 1
    $o = $line | ConvertFrom-Json
    $res.steps["$($Arguments[0])-$($res.steps.Count)"] = [ordered]@{ ms = [math]::Round($t.Elapsed.TotalMilliseconds); out = $o }
    if (-not $o.ok) { throw "hcs $($Arguments[0]): $($o.error)" }
    Log "hcs $($Arguments[0]) ok ($([math]::Round($t.Elapsed.TotalMilliseconds)) ms)"
    $o.result
}

if (-not (Test-Path $Exe)) { throw "Build the host first: cargo build in app/host ($Exe)" }
$tplDir = "C:\GpuVM\.templates\$Template"
$layer = Join-Path $tplDir ((Get-Content (Join-Path $tplDir 'template.json') -Raw | ConvertFrom-Json).layers[-1])
Add-Type -Path (Join-Path $lab065 'hvsock.cs')

try { $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) }
catch [IO.IOException] { throw "The lab lock is held: $(Get-Content $lock -Raw)" }
$fs.Write([Text.Encoding]::UTF8.GetBytes("lab067 pid=$PID $(Get-Date -Format o)")); $fs.Close()
$scratch = Join-Path $env:TEMP "lab067-$PID"; $null = New-Item -ItemType Directory -Force $scratch
try {
    $null = Hcs @('create', $root, $name, $layer, '4096', '4', '--gpu', $Gpu, '--service', "$service")
    $startup = Join-Path $scratch 'probe.cmd'
    Set-Content $startup "@powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\GpuVMLab065\probe.ps1" -Encoding ascii
    Set-Content (Join-Path $scratch 'service.txt') "$service"
    $null = Hcs @('write', $root, $name, 'GpuVMLab065\probe.ps1', (Join-Path $lab065 'guest-probe.ps1'))
    $null = Hcs @('write', $root, $name, 'GpuVMLab065\hvsock.cs', (Join-Path $lab065 'hvsock.cs'))
    $null = Hcs @('write', $root, $name, 'GpuVMLab065\service.txt', (Join-Path $scratch 'service.txt'))
    $null = Hcs @('write', $root, $name, 'ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\gpuvm-lab067.cmd', $startup)

    [HostProbe]::Start($service, [int[]]@(47989, 47984))
    $start = Hcs @('start', $root, $name)
    $res.start = $start
    $t = [Diagnostics.Stopwatch]::StartNew(); $states = [Collections.Generic.List[object]]::new(); $last = ''
    while ($true) {
        $state = (Hcs @('state', $root, $name)).state
        if ($state -ne $last) { $states.Add([ordered]@{ sec = [math]::Round($t.Elapsed.TotalSeconds, 1); state = $state }); $last = $state }
        if ($state -eq 'Off') { break }
        if ($t.Elapsed.TotalSeconds -gt $TimeoutSec) { $states.Add([ordered]@{ sec = [math]::Round($t.Elapsed.TotalSeconds, 1); state = 'timeout' }); $null = Hcs @('off', $root, $name); break }
        Start-Sleep 3
    }
    $res.states = $states
    $res.hostProbe = [ordered]@{ acceptAtSec = [HostProbe]::AcceptAtSec; peerVm = [HostProbe]::PeerVm; received = [HostProbe]::Received; reply = [HostProbe]::Reply; error = [HostProbe]::Error }
    $null = Hcs @('off', $root, $name)

    $disk = Join-Path $root "$name\disk.vhdx"
    $img = Mount-DiskImage -ImagePath $disk -Access ReadOnly -PassThru
    try {
        $part = Get-Disk -Number ($img | Get-DiskImage).Number | Get-Partition | Sort-Object Size -Descending | Select-Object -First 1
        # The volume path Get-Volume reports for a read-only image is not usable here; a drive letter is.
        $part | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue
        $rj = "$(($part | Get-Partition).DriveLetter):\GpuVMLab065\result.json"
        $res.guest = if (Test-Path $rj) { Get-Content $rj -Raw | ConvertFrom-Json } else { 'no result.json' }
    } finally { Dismount-DiskImage -ImagePath $disk | Out-Null }
} catch { $res.error = "$_"; Log "FAILED: $_" }
finally {
    if (-not $Keep) {
        try { if (Test-Path (Join-Path $root "$name\hcs-machine.json")) { $null = Hcs @('off', $root, $name); $null = Hcs @('delete', $root, $name) } } catch { $res.cleanupError = "$_" }
        try { $null = Hcs @('network-delete') } catch { $res.networkCleanupError = "$_" }
    }
    if (-not $Keep) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }; Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
    $res.totalSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $res | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $outDir "$runId.json")
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
    Log "done -> out/$runId.json; left behind: root=$(Test-Path $root) lock=$(Test-Path $lock)"
}
