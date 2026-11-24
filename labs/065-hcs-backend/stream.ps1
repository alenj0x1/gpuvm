# Lab 065, stream: is the picture as smooth through an HCS machine as through Hyper-V? Two copies of the same template
# run at once (same CPUs and memory): one is a GpuVM disposable (Hyper-V, GPU-P), the other an HCS machine (GPU-PV,
# HCN ICS network). Both show tools/latency/motion-target.ps1; Moonlight opens each in turn (borderless) and
# tools/latency/motion-meter.ps1 reads the bar on this screen. Arms and variants are interleaved in rounds.
# Needs an elevated shell in the signed-in session. Takes C:\GpuVM\.lab-lock and leaves nothing behind.
#   pwsh -NoProfile -File labs/065-hcs-backend/stream.ps1 -Rounds 2
param([string]$Template = 'normal-tpl', [int]$Rounds = 2, [double]$Seconds = 20, [int]$MemoryMB = 4096, [int]$Cpu = 4,
    [switch]$Force, [string]$Subnet = '192.168.165', [ValidateSet('main', 'sixty')][string]$Set = 'main',
    # One machine only (nothing else running): the control for what two machines at once cost each other.
    [ValidateSet('both', 'hyperv', 'hcs')][string]$Arms = 'both')
$useHv = $Arms -in 'both', 'hyperv'; $useHcs = $Arms -in 'both', 'hcs'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = $PSScriptRoot
$tools = Join-Path $here '..\..\tools\latency'
. (Join-Path $tools 'common.ps1')
. (Join-Path $tools 'input-meter.ps1')
. (Join-Path $tools 'motion-meter.ps1')
Add-Type -Path (Join-Path $here 'hcs.cs'), (Join-Path $here 'hvsock.cs')
$module = Get-Module GpuVM
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-stream'
$outDir = Join-Path $here 'out'; $null = New-Item -ItemType Directory -Force $outDir
$root = 'C:\GpuVM'; $lock = Join-Path $root '.lab-lock'
$hvName = 'lab065-hv'; $hcsName = 'gpuvm-lab065'
$work = Join-Path $root ".lab065\$runId"; $disk = Join-Path $work 'disk.vhdx'
$service = [guid]'0651ab65-7c1e-4b0a-9a65-065065065065'
$netId = [guid]'0651ab65-0000-4b0a-9a65-0650650650a1'; $epId = [guid]::NewGuid()
$mac = '00-15-5D-{0:X2}-{1:X2}-{2:X2}' -f (Get-Random 256), (Get-Random 256), (Get-Random 256)
$res = [ordered]@{ runId = $runId; template = $Template; memoryMB = $MemoryMB; cpu = $Cpu; results = [Collections.Generic.List[object]]::new() }
$sw = [Diagnostics.Stopwatch]::StartNew()
function Log([string]$m) { Write-Host ("[{0,7:n1}s] {1}" -f $sw.Elapsed.TotalSeconds, $m) }
function Get-VideoBounds([IntPtr]$Window, [int]$Width, [int]$Height) {
    $c = [GpuVMInputMeter]::ClientBounds($Window)
    $scale = [math]::Min($c[2] / $Width, $c[3] / $Height)
    $w = [int]($Width * $scale); $h = [int]($Height * $scale)
    [System.Drawing.Rectangle]::new($c[0] + [int](($c[2] - $w) / 2), $c[1] + [int](($c[3] - $h) / 2), $w, $h)
}
function Wait-Port([string]$Ip, [int]$Port, [int]$TimeoutSec) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    while ($t.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try { $c = [Net.Sockets.TcpClient]::new(); if ($c.ConnectAsync($Ip, $Port).Wait(2000) -and $c.Connected) { $c.Dispose(); return [math]::Round($t.Elapsed.TotalSeconds, 1) }; $c.Dispose() } catch {}
        Start-Sleep 2
    }
    throw "No answer on ${Ip}:$Port after $TimeoutSec s."
}

$tplDir = Join-Path $root ".templates\$Template"
$tplRaw = Get-Content (Join-Path $tplDir 'template.json') -Raw
$tpl = $tplRaw | ConvertFrom-Json
$tplState = $tplRaw | ConvertFrom-Json -AsHashtable
$layers = @($tpl.layers | ForEach-Object { Join-Path $tplDir $_ })
$gpuPath = [Hcs]::PartitionableGpus() | Where-Object { $_ -match 'VEN_10DE' } | Select-Object -First 1
if (-not $gpuPath) { throw 'No partitionable NVIDIA GPU.' }
$freeMB = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB
$needMB = ([int]$useHv + [int]$useHcs) * $MemoryMB + 1024
if ($freeMB -lt $needMB) { throw "Only $([int]$freeMB) MB free, need $needMB." }
$res.arms = $Arms
if (Get-VM -Name $hvName -ErrorAction SilentlyContinue) { throw "$hvName already exists." }
$res.hostGpuPctBefore = Assert-LatencyGpuIdle -Force:$Force
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$hostHz = (Get-CimInstance Win32_VideoController | Where-Object CurrentRefreshRate | Select-Object -First 1).CurrentRefreshRate
$res.hostScreen = "$($screen.Width)x$($screen.Height)@$hostHz"

try { $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) }
catch [IO.IOException] { throw "The lab lock is held: $(Get-Content $lock -Raw)" }
$fs.Write([Text.Encoding]::UTF8.GetBytes("lab065-stream pid=$PID $(Get-Date -Format o)")); $fs.Close()

$cs = [IntPtr]::Zero
$granted = [Collections.Generic.List[string]]::new()
try {
    $sunshine = & $module { param($s) Get-SunshineCredential -State $s } $tplState
    $vms = [Collections.Generic.List[object]]::new()
    if ($useHv) {
    # Hyper-V arm: a GpuVM disposable of the template.
    Log 'Hyper-V copy: creating'
    New-GpuVM -Name $hvName -Template $Template -Disposable -Override @{ vm = @{ memoryGB = [int]($MemoryMB / 1024); cpu = @{ count = $Cpu } } } -Confirm:$false | Out-Null
    $hvVm = Get-LatencyVM -Name $hvName
    Log "Hyper-V copy: address $($hvVm.Address)"
    $vms.Add([pscustomobject]@{ Name = 'hyperv'; Vm = $hvVm })
    }

    if ($useHcs) {
    # HCS arm.
    $null = New-Item -ItemType Directory -Force $work
    $null = New-VHD -Path $disk -ParentPath $layers[-1] -Differencing
    $img = Mount-DiskImage -ImagePath $disk -PassThru
    try {
        $part = Get-Disk -Number ($img | Get-DiskImage).Number | Get-Partition | Sort-Object Size -Descending | Select-Object -First 1
        if (-not ($part | Get-Volume).DriveLetter) { $part | Add-PartitionAccessPath -AssignDriveLetter; $part = $part | Get-Partition }
        $drive = "$(($part | Get-Volume).DriveLetter):\"
        $gdir = Join-Path $drive 'GpuVMLab065'; $null = New-Item -ItemType Directory -Force $gdir
        Copy-Item (Join-Path $here 'stream-guest.ps1'), (Join-Path $here 'hvsock.cs'), (Join-Path $tools 'motion-target.ps1'), (Join-Path $here '..\..\guest\set-resolution.ps1') $gdir
        Set-Content (Join-Path $gdir 'service.txt') "$service"
        & reg.exe load 'HKLM\L065SW' (Join-Path $drive 'Windows\System32\config\SOFTWARE') | Out-Null
        if ($LASTEXITCODE) { throw 'reg load failed' }
        try { & reg.exe add 'HKLM\L065SW\Microsoft\Windows\CurrentVersion\Run' /v GpuVMLab065 /t REG_SZ /f /d 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\GpuVMLab065\stream-guest.ps1' | Out-Null }
        finally { [GC]::Collect(); & reg.exe unload 'HKLM\L065SW' | Out-Null }
    } finally { Dismount-DiskImage -ImagePath $disk | Out-Null }
    $vmgs = Join-Path $work 'vm.vmgs'; $vmrs = Join-Path $work 'vm.vmrs'
    if ([Hcs]::HcsCreateEmptyGuestStateFile($vmgs) -or [Hcs]::HcsCreateEmptyRuntimeStateFile($vmrs)) { throw 'state files' }
    foreach ($f in @($disk, $vmgs, $vmrs) + $layers) { if ([Hcs]::HcsGrantVmAccess($hcsName, $f)) { throw "grant $f" }; $granted.Add($f) }
    $net = [ordered]@{ SchemaVersion = @{ Major = 2; Minor = 0 }; Name = 'GpuVMLab065'; Type = 'ICS'; Flags = 11
        Ipams = @(@{ Type = 'Static'; Subnets = @(@{ IpAddressPrefix = "$Subnet.0/24"; Routes = @(@{ NextHop = "$Subnet.1"; DestinationPrefix = '0.0.0.0/0' }) }) }) } | ConvertTo-Json -Depth 10 -Compress
    $x = [Hcs]::CreateNetwork($netId, $net); if ($x.Hr) { throw "network: $x" }
    $x = [Hcs]::CreateEndpoint($netId, $epId, (@{ SchemaVersion = @{ Major = 2; Minor = 0 }; HostComputeNetwork = "$netId"; MacAddress = $mac } | ConvertTo-Json -Compress)); if ($x.Hr) { throw "endpoint: $x" }
    $vm = [ordered]@{
        StopOnReset = $false
        Chipset = [ordered]@{ Uefi = [ordered]@{ Console = 'Default'; ApplySecureBootTemplate = 'Apply'; SecureBootTemplateId = '1734c6e8-3154-4dda-ba5f-a874cc483422' } }
        ComputeTopology = [ordered]@{ Memory = [ordered]@{ SizeInMB = $MemoryMB }; Processor = [ordered]@{ Count = $Cpu } }
        Devices = [ordered]@{
            Scsi = [ordered]@{ Primary = [ordered]@{ Attachments = [ordered]@{ '0' = [ordered]@{ Type = 'VirtualDisk'; Path = $disk } } } }
            VideoMonitor = [ordered]@{ HorizontalResolution = 1024; VerticalResolution = 768 }
            HvSocket = [ordered]@{ HvSocketConfig = [ordered]@{ ServiceTable = [ordered]@{
                        "$service" = [ordered]@{ BindSecurityDescriptor = 'D:P(A;;FA;;;SY)(A;;FA;;;BA)'; ConnectSecurityDescriptor = 'D:P(A;;FA;;;WD)'; AllowWildcardBinds = $true } } } }
            Keyboard = @{}; Mouse = @{}
            NetworkAdapters = [ordered]@{ Default = [ordered]@{ EndpointId = "$epId"; MacAddress = $mac } }
        }
        GuestState = [ordered]@{ GuestStateFilePath = $vmgs; RuntimeStateFilePath = $vmrs }
    }
    $json = [ordered]@{ SchemaVersion = [ordered]@{ Major = 2; Minor = 1 }; Owner = 'GpuVMLab065'; ShouldTerminateOnLastHandleClosed = $true; VirtualMachine = $vm } | ConvertTo-Json -Depth 20 -Compress
    [HostChannel]::Start($service)
    $x = [Hcs]::Create($hcsName, $json, [ref]$cs); if ($x.Hr) { throw "create: $x" }
    $x = [Hcs]::Start($cs); if ($x.Hr) { throw "start: $x" }
    $gpu = [ordered]@{ ResourcePath = 'VirtualMachine/ComputeTopology/Gpu'; RequestType = 'Update'; Settings = [ordered]@{ AssignmentMode = 'List'; AssignmentRequest = @{ $gpuPath = 65535 }; AllowVendorExtension = $true } } | ConvertTo-Json -Depth 10 -Compress
    $x = [Hcs]::Modify($cs, $gpu); if ($x.Hr) { throw "gpu: $x" }
    Log 'HCS copy: started, waiting for its address over the Hyper-V socket'
    $t = [Diagnostics.Stopwatch]::StartNew()
    while (-not ([HostChannel]::Hello -match '^ip=\d')) {
        if ($t.Elapsed.TotalSeconds -gt 300) { throw "No address from the HCS copy in 300 s ($([HostChannel]::Hello) $([HostChannel]::Error))" }
        Start-Sleep 1
    }
    $hcsIp = ([HostChannel]::Hello -replace '^ip=').Trim()
    $res.hcsAddressSec = [math]::Round($t.Elapsed.TotalSeconds, 1)
    Log "HCS copy: address $hcsIp after $($res.hcsAddressSec) s"
    $hcsVm = [pscustomobject]@{ Name = $hcsName; Module = $module; Address = $hcsIp; Sunshine = $sunshine }
    $vms.Add([pscustomobject]@{ Name = 'hcs'; Vm = $hcsVm })
    }

    $res.sunshineReadySec = [ordered]@{}
    foreach ($a in $vms) { $res.sunshineReadySec[$a.Name] = Wait-Port $a.Vm.Address 47989 300 }
    if ($useHv) { & (Join-Path $tools 'start-target.ps1') -Name $hvName -Minutes 120 -Script motion-target.ps1 | Write-Host }
    $moonlightExe = Join-Path $env:ProgramFiles 'Moonlight Game Streaming\Moonlight.exe'
    foreach ($v in $vms.Vm) {
        $hostIp = (Find-NetRoute -RemoteIPAddress $v.Address | Where-Object IPAddress | Select-Object -First 1).IPAddress
        $paired = & $module {
            param($a, $c, $m, $h)
            $client = "$env:COMPUTERNAME lab065"
            if (Test-SunshineClientPaired -Address $a -Credential $c -ClientName $client) { return 'already' }
            $pin = '{0:D4}' -f [Security.Cryptography.RandomNumberGenerator]::GetInt32(0, 10000)
            $task = Start-UnelevatedProcess -FilePath $m -ArgumentList @('pair', $a, '--pin', $pin) -KeepTask
            try {
                $deadline = (Get-Date).AddSeconds(60); $sent = $false
                while (-not $sent -and (Get-Date) -lt $deadline) {
                    $req = Select-MoonlightPairingRequest -Pending @((Invoke-SunshineApi -Address $a -Credential $c -Path '/api/pin').pairings) -HostAddress $h -ClientName $client
                    if ($req) { $null = Invoke-SunshineApi -Address $a -Credential $c -Method POST -Path '/api/pin' -Body @{ pairing_id = [string]$req.id; pin = $pin; name = $client }; $sent = $true } else { Start-Sleep 1 }
                }
                if (-not $sent) { throw 'Moonlight did not ask to pair in 60 s.' }
                $deadline = (Get-Date).AddSeconds(30)
                while (-not (Test-SunshineClientPaired -Address $a -Credential $c -ClientName $client)) { if ((Get-Date) -gt $deadline) { throw 'Sunshine did not record the pairing.' }; Start-Sleep 1 }
                'paired'
            } finally { Remove-UnelevatedTask -TaskName $task; Get-Process Moonlight -ErrorAction SilentlyContinue | Stop-Process -Force }
        } $v.Address $v.Sunshine $moonlightExe $hostIp
        if ($paired -ne 'already') { Start-Sleep 3 }
        Log "paired Moonlight with $($v.Name) ($($v.Address), host side $hostIp)"
    }
    Start-Sleep 10

    $armList = @($vms)
    $variants = if ($Set -eq 'sixty') {
        @(
            [pscustomobject]@{ Name = '60-pacing-display179'; Display = 179; Client = @{ fps = 60; vsync = $true; framePacing = $true } }
            [pscustomobject]@{ Name = '60-pacing-display60'; Display = 60; Client = @{ fps = 60; vsync = $true; framePacing = $true } }
            [pscustomobject]@{ Name = '60-vsync-display60'; Display = 60; Client = @{ fps = 60; vsync = $true; framePacing = $false } }
        )
    } else {
        @(
            [pscustomobject]@{ Name = 'auto-vsync'; Display = 179; Client = @{ fps = 0; vsync = $true; framePacing = $false } }
            [pscustomobject]@{ Name = '60-vsync-pacing'; Display = 60; Client = @{ fps = 60; vsync = $true; framePacing = $true } }
            [pscustomobject]@{ Name = '120-novsync'; Display = 120; Client = @{ fps = 120; vsync = $false; framePacing = $false } }
        )
    }
    $display = @{ hyperv = 179; hcs = 179 }
    $res.displayChanges = [Collections.Generic.List[object]]::new()
    for ($round = 1; $round -le $Rounds; $round++) {
        $order = @($armList); if (-not ($round % 2)) { [array]::Reverse($order) }
        foreach ($variant in $variants) {
            foreach ($arm in $order) {
                if ($display[$arm.Name] -ne $variant.Display) {
                    $reply = if ($arm.Name -eq 'hyperv') { & $module { param($n, $c, $f) Set-GuestDisplayResolution -Name $n -Credential $c -Resolution '1920x1080' -Fps $f } $hvName $hvVm.Guest $variant.Display | ConvertTo-Json -Compress }
                    else { [HostChannel]::Ask("mode 1920 1080 $($variant.Display)", 30000) }
                    $display[$arm.Name] = $variant.Display
                    $res.displayChanges.Add([ordered]@{ arm = $arm.Name; hz = $variant.Display; reply = "$reply" })
                    Log "$($arm.Name) display -> $($variant.Display) Hz: $reply"
                    Start-Sleep 2
                }
                $client = [ordered]@{ app = 'Desktop'; resolution = '1920x1080'; displayMode = 'borderless'; mouse = 'capture'; captureSystemKeys = 'never' }
                foreach ($k in $variant.Client.Keys) { $client[$k] = $variant.Client[$k] }
                $fps = [int](& $module { param($f) Resolve-GpuVMStreamFps $f } $client['fps'])
                $arguments = & $module { param($a, $c) Get-MoonlightStreamArguments -Address $a -Client $c } $arm.Vm.Address $client
                $started = Get-Date
                $session = Start-LatencyViewer -Viewer moonlight -Arguments $arguments
                $firstFrameSec = Wait-LatencyViewerFrame $session -Since $started
                $session.Process.Refresh()
                $null = [GpuVMInputMeter]::BringToFront($session.Process.MainWindowHandle)
                Start-Sleep -Milliseconds 500
                $bounds = Get-VideoBounds $session.Process.MainWindowHandle 1920 1080
                $wait = [Diagnostics.Stopwatch]::StartNew(); $pictureSec = -1
                while ($wait.Elapsed.TotalSeconds -lt 60) {
                    $probe = Measure-Motion -Bounds $bounds -Fps $fps -Seconds 0.5
                    if (-not $probe.PSObject.Properties['error']) { $pictureSec = [math]::Round($firstFrameSec + $wait.Elapsed.TotalSeconds, 1); break }
                }
                Start-Sleep 2
                $gpuBefore = [int](& nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | Select-Object -First 1)
                $row = Measure-Motion -Bounds $bounds -Fps $fps -Seconds $Seconds
                $gpuAfter = [int](& nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | Select-Object -First 1)
                $row | Add-Member arm $arm.Name -PassThru | Add-Member variant $variant.Name -PassThru | Add-Member round $round -PassThru | Add-Member fps $fps -PassThru |
                    Add-Member firstFrameSec $firstFrameSec -PassThru | Add-Member pictureSec $pictureSec -PassThru | Add-Member hostGpuPct @($gpuBefore, $gpuAfter) -PassThru |
                    Add-Member arguments ($arguments -join ' ') | Out-Null
                $res.results.Add($row)
                if ($row.PSObject.Properties['error']) {
                    Save-ScreenRegion -Path (Join-Path $outDir "$runId-$($arm.Name)-$($variant.Name)-r$round.png")
                    Log "$($arm.Name) $($variant.Name) r$round : $($row.error) (picture $pictureSec s)"
                } else { Log ("{0,-6} {1,-16} r{2}: {3} upd/s sd {4} ms p99 {5} ms stutter {6} % speedCV {7} % (picture {8} s)" -f $arm.Name, $variant.Name, $round, $row.updatesPerSec, $row.intervalSdMs, $row.intervalP99Ms, $row.stutterPct, $row.speedCvPct, $pictureSec) }
                Stop-LatencyStream $session -VM $arm.Vm
                if ($round -eq 1 -and $variant -eq $variants[0] -and $pictureSec -lt 0) { throw "Control failed: no picture from $($arm.Name) on the first sample; stopping before the rest." }
            }
        }
    }
} catch { $res.error = "$_"; Log "FAILED: $_"; try { Save-ScreenRegion -Path (Join-Path $outDir "$runId-failure.png") } catch {} }
finally {
    Stop-LatencyViewers
    [HostChannel]::Close()
    if ($cs -ne [IntPtr]::Zero) { try { $null = [Hcs]::Terminate($cs) } catch {}; [Hcs]::Close($cs) }
    $res.hcnCleanup = "ep=$([Hcs]::DeleteEndpoint($epId).Hr) net=$([Hcs]::DeleteNetwork($netId).Hr)"
    try { if (Get-VM -Name $hvName -ErrorAction SilentlyContinue) { Stop-VM $hvName -Force -TurnOff -ErrorAction SilentlyContinue; Start-Sleep 3; if (Get-VM -Name $hvName -ErrorAction SilentlyContinue) { Remove-GpuVM -Name $hvName -DeleteDisk -Confirm:$false } } } catch { $res.hvCleanupError = "$_" }
    for ($i = 0; $i -lt 30 -and (Test-Path $disk); $i++) { try { [IO.File]::Open($disk, 'Open', 'Read', 'None').Close(); break } catch { Start-Sleep 1 } }
    foreach ($f in $granted) { $null = [Hcs]::HcsRevokeVmAccess($hcsName, $f) }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Get-ChildItem (Join-Path $root '.lab065') -ErrorAction SilentlyContinue)) { Remove-Item (Join-Path $root '.lab065') -Force -ErrorAction SilentlyContinue }
    $res.totalSec = [math]::Round($sw.Elapsed.TotalSeconds)
    $res | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $outDir "$runId.json")
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
    Log "done -> out/$runId.json; left behind: hv=$([bool](Get-VM -Name $hvName -ErrorAction SilentlyContinue)) work=$(Test-Path $work) lock=$(Test-Path $lock)"
}
