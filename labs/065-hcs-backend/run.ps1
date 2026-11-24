# Lab 065: can GpuVM run its machines through the Host Compute Service (HCS, what WSL2 uses) instead of Hyper-V
# (VMMS), with the GPU shared by GPU-PV? HCS only needs "Virtual Machine Platform", which Windows Home has.
#   pwsh -NoProfile -File labs/065-hcs-backend/run.ps1 -Gpu Nvidia    # GPU-PV with the RTX
#   pwsh -NoProfile -File labs/065-hcs-backend/run.ps1 -Gpu None      # negative control, no GPU
# A differencing disk over a template, a probe injected offline that records what the guest sees and shuts it down,
# no network. Needs an elevated shell. Takes C:\GpuVM\.lab-lock for the whole run and leaves nothing behind.
param([ValidateSet('Nvidia', 'Intel', 'Default', 'None')][string]$Gpu = 'Nvidia', [string]$Template = 'normal-tpl',
    [int]$MemoryMB = 4096, [int]$Cpu = 4, [int]$TimeoutSec = 600, [int]$MaxBoots = 4, [switch]$NoTpm, [switch]$StopOnResetFalse,
    [ValidateSet('None', 'ICS')][string]$Network = 'None', [string]$Subnet = '192.168.165')
$service = [guid]'0651ab65-7c1e-4b0a-9a65-065065065065'
$netId = [guid]'0651ab65-0000-4b0a-9a65-0650650650a1'
$epId = [guid]::NewGuid()
$mac = '00-15-5D-{0:X2}-{1:X2}-{2:X2}' -f (Get-Random 256), (Get-Random 256), (Get-Random 256)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = $PSScriptRoot
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$($Gpu.ToLower())"
$name = 'gpuvm-lab065'
$root = 'C:\GpuVM'
$lock = Join-Path $root '.lab-lock'
$work = Join-Path $root ".lab065\$runId"
$outDir = Join-Path $here 'out'
$null = New-Item -ItemType Directory -Force $outDir
$res = [ordered]@{ runId = $runId; gpu = $Gpu; template = $Template; memoryMB = $MemoryMB; cpu = $Cpu; tpm = -not $NoTpm; steps = [ordered]@{} }
$sw = [Diagnostics.Stopwatch]::StartNew()
function Log([string]$m) { Write-Host ("[{0,6:n1}s] {1}" -f $sw.Elapsed.TotalSeconds, $m) }
function Get-State([IntPtr]$h) {
    $p = [Hcs]::Properties($h)
    if ($p.Hr) { return @('gone:0x{0:X8}' -f $p.Hr, $null) }
    $o = $p.Doc | ConvertFrom-Json
    if ($o -and $o.PSObject.Properties['State']) { return @($o.State, $p.Doc) }
    @('nostate', $p.Doc)
}
function Step([string]$Key, [scriptblock]$Body) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    try { $v = & $Body; $res.steps[$Key] = [ordered]@{ ok = $true; sec = [math]::Round($t.Elapsed.TotalSeconds, 2); value = $v }; Log "$Key ok ($([math]::Round($t.Elapsed.TotalSeconds,1)) s)"; $v }
    catch { $res.steps[$Key] = [ordered]@{ ok = $false; sec = [math]::Round($t.Elapsed.TotalSeconds, 2); error = "$_" }; Log "$Key FAILED: $_"; throw }
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Needs an elevated shell.' }
Add-Type -Path (Join-Path $here 'hcs.cs'), (Join-Path $here 'hvsock.cs')
$tplDir = Join-Path $root ".templates\$Template"
$tpl = Get-Content (Join-Path $tplDir 'template.json') -Raw | ConvertFrom-Json
$layers = @($tpl.layers | ForEach-Object { Join-Path $tplDir $_ })
foreach ($l in $layers) { if (-not (Test-Path $l)) { throw "Missing template layer $l" } }
$freeMB = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB
if ($freeMB -lt $MemoryMB + 1024) { throw "Only $([int]$freeMB) MB free, need $($MemoryMB + 1024)." }
if ((Get-Service vmcompute).Status -ne 'Running') { Start-Service vmcompute }
$gpuPath = $null
if ($Gpu -in 'Nvidia', 'Intel') {
    $ven = @{ Nvidia = 'VEN_10DE'; Intel = 'VEN_8086' }[$Gpu]
    $gpuPath = [Hcs]::PartitionableGpus() | Where-Object { $_ -match $ven } | Select-Object -First 1
    if (-not $gpuPath) { throw "No partitionable $Gpu GPU." }
}
$res.gpuPath = $gpuPath
$res.host = [ordered]@{ os = (Get-CimInstance Win32_OperatingSystem).Caption; build = [Environment]::OSVersion.Version.ToString() }

try { $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) }
catch [IO.IOException] { throw "The lab lock is held: $(Get-Content $lock -Raw)" }
$fs.Write([Text.Encoding]::UTF8.GetBytes("lab065 pid=$PID $(Get-Date -Format o)")); $fs.Close()

$cs = [IntPtr]::Zero
$granted = [Collections.Generic.List[string]]::new()
$disk = Join-Path $work 'disk.vhdx'
$started = Get-Date
try {
    $null = New-Item -ItemType Directory -Force $work
    Step 'disk.child' { $null = New-VHD -Path $disk -ParentPath $layers[-1] -Differencing; (Get-Item $disk).Length }

    Step 'disk.inject' {
        $img = Mount-DiskImage -ImagePath $disk -PassThru
        try {
            $vol = Get-Disk -Number ($img | Get-DiskImage).Number | Get-Partition | Get-Volume | Where-Object { $_.DriveLetter -or $_.Path } |
                Where-Object { $p = if ($_.DriveLetter) { "$($_.DriveLetter):\" } else { $_.Path }; Test-Path (Join-Path $p 'Windows\System32\config\SOFTWARE') } | Select-Object -First 1
            if (-not $vol) {
                $part = Get-Disk -Number ($img | Get-DiskImage).Number | Get-Partition | Sort-Object Size -Descending | Select-Object -First 1
                $part | Add-PartitionAccessPath -AssignDriveLetter
                $vol = $part | Get-Volume
            }
            $drive = if ($vol.DriveLetter) { "$($vol.DriveLetter):\" } else { $vol.Path }
            $gdir = Join-Path $drive 'GpuVMLab065'
            $null = New-Item -ItemType Directory -Force $gdir
            Copy-Item (Join-Path $here 'guest-probe.ps1') (Join-Path $gdir 'probe.ps1') -Force
            Copy-Item (Join-Path $here 'hvsock.cs') (Join-Path $gdir 'hvsock.cs') -Force
            Set-Content (Join-Path $gdir 'service.txt') $service.ToString()
            $hive = Join-Path $drive 'Windows\System32\config\SOFTWARE'
            & reg.exe load 'HKLM\L065SW' $hive | Out-Null
            if ($LASTEXITCODE) { throw "reg load failed ($LASTEXITCODE)" }
            try {
                & reg.exe add 'HKLM\L065SW\Microsoft\Windows\CurrentVersion\Run' /v GpuVMLab065 /t REG_SZ /f /d 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\GpuVMLab065\probe.ps1' | Out-Null
                if ($LASTEXITCODE) { throw "reg add failed ($LASTEXITCODE)" }
            } finally { [GC]::Collect(); & reg.exe unload 'HKLM\L065SW' | Out-Null }
            $drive
        } finally { Dismount-DiskImage -ImagePath $disk | Out-Null }
    }

    Step 'access.grant' {
        $vmgs = Join-Path $work 'vm.vmgs'; $vmrs = Join-Path $work 'vm.vmrs'
        $hr1 = [Hcs]::HcsCreateEmptyGuestStateFile($vmgs); $hr2 = [Hcs]::HcsCreateEmptyRuntimeStateFile($vmrs)
        if ($hr1 -or $hr2) { throw ('state files 0x{0:X8} 0x{1:X8}' -f $hr1, $hr2) }
        foreach ($f in @($disk, $vmgs, $vmrs) + $layers) {
            $hr = [Hcs]::HcsGrantVmAccess($name, $f)
            if ($hr) { throw ('GrantVmAccess {0}: 0x{1:X8}' -f $f, $hr) }
            $granted.Add($f)
        }
        $granted.Count
    }

    $uefi = [ordered]@{ Console = 'Default'; ApplySecureBootTemplate = 'Apply'; SecureBootTemplateId = '1734c6e8-3154-4dda-ba5f-a874cc483422' }
    $vm = [ordered]@{
        Chipset = [ordered]@{ Uefi = $uefi }
        ComputeTopology = [ordered]@{
            Memory = [ordered]@{ SizeInMB = $MemoryMB; AllowOvercommit = $true; EnableDeferredCommit = $true }
            Processor = [ordered]@{ Count = $Cpu }
        }
        Devices = [ordered]@{
            Scsi = [ordered]@{ Primary = [ordered]@{ Attachments = [ordered]@{ '0' = [ordered]@{ Type = 'VirtualDisk'; Path = $disk } } } }
            VideoMonitor = [ordered]@{ HorizontalResolution = 1024; VerticalResolution = 768 }
            HvSocket = [ordered]@{ HvSocketConfig = [ordered]@{ ServiceTable = [ordered]@{
                        "$service" = [ordered]@{ BindSecurityDescriptor = 'D:P(A;;FA;;;SY)(A;;FA;;;BA)'; ConnectSecurityDescriptor = 'D:P(A;;FA;;;WD)'; AllowWildcardBinds = $true } } } }
            Keyboard = @{}
            Mouse = @{}
        }
        GuestState = [ordered]@{ GuestStateFilePath = (Join-Path $work 'vm.vmgs'); RuntimeStateFilePath = (Join-Path $work 'vm.vmrs') }
    }
    if ($StopOnResetFalse) { $vm.StopOnReset = $false }
    if ($Network -eq 'ICS') {
        Step 'hcn.network' {
            $r = [Hcs]::CreateNetwork($netId, ([ordered]@{ SchemaVersion = @{ Major = 2; Minor = 0 }; Name = 'GpuVMLab065'; Type = 'ICS'; Flags = 11
                    Ipams = @(@{ Type = 'Static'; Subnets = @(@{ IpAddressPrefix = "$Subnet.0/24"; Routes = @(@{ NextHop = "$Subnet.1"; DestinationPrefix = '0.0.0.0/0' }) }) }) } | ConvertTo-Json -Depth 10 -Compress))
            if ($r.Hr) { throw $r.ToString() }; 'created'
        } | Out-Null
        Step 'hcn.endpoint' {
            $r = [Hcs]::CreateEndpoint($netId, $epId, (@{ SchemaVersion = @{ Major = 2; Minor = 0 }; HostComputeNetwork = $netId.ToString(); MacAddress = $mac } | ConvertTo-Json -Compress))
            if ($r.Hr) { throw $r.ToString() }; $epId.ToString()
        } | Out-Null
        $vm.Devices.NetworkAdapters = [ordered]@{ Default = [ordered]@{ EndpointId = $epId.ToString(); MacAddress = $mac } }
    }
    [HostProbe]::Start($service, [int[]]@(47989, 47984, 22))
    if (-not $NoTpm) { $vm.SecuritySettings = [ordered]@{ EnableTpm = $true; Isolation = [ordered]@{ IsolationType = 'GuestStateOnly' } } }
    $config = [ordered]@{ SchemaVersion = [ordered]@{ Major = 2; Minor = 1 }; Owner = 'GpuVMLab065'; ShouldTerminateOnLastHandleClosed = $true; VirtualMachine = $vm }
    $json = $config | ConvertTo-Json -Depth 20 -Compress
    Set-Content (Join-Path $outDir "$runId.config.json") $json

    $settings = if ($gpuPath) { [ordered]@{ AssignmentMode = 'List'; AssignmentRequest = @{ $gpuPath = 65535 }; AllowVendorExtension = $true } }
    else { [ordered]@{ AssignmentMode = 'Default'; AllowVendorExtension = $true } }
    $mod = [ordered]@{ ResourcePath = 'VirtualMachine/ComputeTopology/Gpu'; RequestType = 'Update'; Settings = $settings } | ConvertTo-Json -Depth 10 -Compress
    $started = Get-Date
    $res.boots = [Collections.Generic.List[object]]::new()
    for ($boot = 1; $boot -le $MaxBoots; $boot++) {
        $b = [ordered]@{ boot = $boot; atSec = [math]::Round(((Get-Date) - $started).TotalSeconds, 1) }
        $res.boots.Add($b)
        Step "hcs.create.$boot" { $r = [Hcs]::Create($name, $json, [ref]$cs); if ($r.Hr) { throw $r.ToString() }; $r.Doc } | Out-Null
        Step "hcs.start.$boot" { $r = [Hcs]::Start($cs); if ($r.Hr) { throw $r.ToString() }; $r.Doc } | Out-Null
        if ($Gpu -ne 'None') { Step "hcs.gpu.$boot" { $r = [Hcs]::Modify($cs, $mod); if ($r.Hr) { throw $r.ToString() }; 'applied' } | Out-Null }
        $t = [Diagnostics.Stopwatch]::StartNew(); $last = ''; $b.states = [Collections.Generic.List[object]]::new()
        while ($true) {
            $state, $doc = Get-State $cs
            if ($state -ne $last) { $b.states.Add([ordered]@{ sec = [math]::Round($t.Elapsed.TotalSeconds, 1); state = $state; doc = $doc }); Log "boot $boot state $state"; $last = $state }
            if ($state -ne 'Running') { break }
            if (((Get-Date) - $started).TotalSeconds -gt $TimeoutSec) { $b.timeout = $true; $null = [Hcs]::Terminate($cs); break }
            Start-Sleep -Milliseconds 1000
        }
        $b.runSec = [math]::Round($t.Elapsed.TotalSeconds, 1)
        [Hcs]::Close($cs); $cs = [IntPtr]::Zero
        if ($b.Contains('timeout')) { break }
        for ($i = 0; $i -lt 30; $i++) { try { [IO.File]::Open($disk, 'Open', 'Read', 'None').Close(); break } catch { Start-Sleep 1 } }
        $img = Mount-DiskImage -ImagePath $disk -Access ReadOnly -PassThru
        try {
            $part = Get-Disk -Number ($img | Get-DiskImage).Number | Get-Partition | Sort-Object Size -Descending | Select-Object -First 1
            $vol = $part | Get-Volume
            $drive = if ($vol.DriveLetter) { "$($vol.DriveLetter):\" } else { $vol.Path }
            $b.probeDone = Test-Path (Join-Path $drive 'GpuVMLab065\result.json')
        } finally { Dismount-DiskImage -ImagePath $disk | Out-Null }
        Log "boot $boot ended after $($b.runSec) s, probe done: $($b.probeDone)"
        if ($b.probeDone) { break }
    }
} finally {
    if ($cs -ne [IntPtr]::Zero) {
        try { if ((Get-State $cs)[0] -eq 'Running') { $null = [Hcs]::Terminate($cs) } } catch { $res.terminateError = "$_" }
        [Hcs]::Close($cs)
    }
    $res.totalSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $res.hostProbe = [ordered]@{ acceptAtSec = [HostProbe]::AcceptAtSec; peerVm = [HostProbe]::PeerVm; received = [HostProbe]::Received; reply = [HostProbe]::Reply; error = [HostProbe]::Error }
    if ($Network -eq 'ICS') {
        $res.hcnCleanup = "ep=$([Hcs]::DeleteEndpoint($epId).Hr) net=$([Hcs]::DeleteNetwork($netId).Hr)"
    }
    try {
        if (Test-Path $disk) {
            for ($i = 0; $i -lt 30; $i++) { try { [IO.File]::Open($disk, 'Open', 'Read', 'None').Close(); break } catch { Start-Sleep 1 } }
            $img = Mount-DiskImage -ImagePath $disk -Access ReadOnly -PassThru
            try {
                $part = Get-Disk -Number ($img | Get-DiskImage).Number | Get-Partition | Sort-Object Size -Descending | Select-Object -First 1
                $vol = $part | Get-Volume
                $drive = if ($vol.DriveLetter) { "$($vol.DriveLetter):\" } else { $vol.Path }
                $rj = Join-Path $drive 'GpuVMLab065\result.json'
                $res.guest = if (Test-Path $rj) { Get-Content $rj -Raw | ConvertFrom-Json } else { 'no result.json (probe did not run or did not finish)' }
                $dx = Join-Path $drive 'GpuVMLab065\dxdiag.txt'
                if (Test-Path $dx) { Copy-Item $dx (Join-Path $outDir "$runId.dxdiag.txt") }
                $res.childDiskMB = [math]::Round((Get-Item $disk).Length / 1MB, 1)
                $res.guestChangedFiles = @(Get-ChildItem $drive -Recurse -File -Force -ErrorAction SilentlyContinue -Include *.log, *.evtx, *.dmp, *.etl, *.txt, *.json, bootstat.dat |
                    Where-Object { $_.LastWriteTime -gt $started } | Sort-Object LastWriteTime | Select-Object -First 60 | ForEach-Object { '{0:HH:mm:ss} {1}' -f $_.LastWriteTime, $_.FullName.Substring($drive.Length) })
                $evtx = Join-Path $drive 'Windows\System32\winevt\Logs\System.evtx'
                if (Test-Path $evtx) {
                    $res.guestSystemErrors = @(Get-WinEvent -Path $evtx -MaxEvents 400 -ErrorAction SilentlyContinue | Where-Object { $_.Level -le 2 } |
                        Select-Object -First 25 | ForEach-Object { [ordered]@{ t = $_.TimeCreated.ToString('o'); id = $_.Id; src = $_.ProviderName; msg = ("$($_.Message)" -split "`n")[0] } })
                }
            } finally { Dismount-DiskImage -ImagePath $disk | Out-Null }
        }
    } catch { $res.readBackError = "$_" }
    foreach ($f in $granted) { $null = [Hcs]::HcsRevokeVmAccess($name, $f) }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Get-ChildItem (Join-Path $root '.lab065') -ErrorAction SilentlyContinue)) { Remove-Item (Join-Path $root '.lab065') -Force -ErrorAction SilentlyContinue }
    $res | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $outDir "$runId.json")
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
    Log "done -> out/$runId.json; left behind: work=$(Test-Path $work) lock=$(Test-Path $lock) system=$([bool]([Hcs]::Enumerate().Doc -match $name))"
}
