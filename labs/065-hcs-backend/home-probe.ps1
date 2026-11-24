# Runs inside a Windows Home guest (PowerShell Direct, admin). Proves what a GpuVM HCS backend needs, using only what
# Home has: Virtual Machine Platform (HCS + HCN), diskpart for disks; no Hyper-V module. Returns one object.
param([string]$Dir = 'C:\GpuVMLab065')
$ErrorActionPreference = 'Stop'
$r = [ordered]@{}
function Try-Step([string]$Key, [scriptblock]$Body) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    Add-Content (Join-Path $Dir 'progress.txt') "$(Get-Date -Format o) start $Key"
    try { $r[$Key] = [ordered]@{ ok = $true; ms = 0; value = (& $Body) } } catch { $r[$Key] = [ordered]@{ ok = $false; ms = 0; error = "$_" } }
    $r[$Key].ms = [math]::Round($t.Elapsed.TotalMilliseconds)
    Add-Content (Join-Path $Dir 'progress.txt') "$(Get-Date -Format o) end $Key $($r[$Key] | ConvertTo-Json -Compress -Depth 4)"
}
$os = Get-CimInstance Win32_OperatingSystem
$r.edition = $os.Caption; $r.build = $os.BuildNumber
$r.features = @(Get-WindowsOptionalFeature -Online | Where-Object { $_.FeatureName -match 'Hyper-V|VirtualMachinePlatform|HypervisorPlatform|Containers' } |
    ForEach-Object { "$($_.FeatureName)=$($_.State)" })
$r.services = @('vmcompute', 'hns', 'vmms', 'vfpext') | ForEach-Object { $s = Get-Service $_ -ErrorAction SilentlyContinue; "$_=$(if ($s) { $s.Status } else { 'absent' })" }
$r.hyperVModule = [bool](Get-Module -ListAvailable Hyper-V)
$r.computecoreDll = Test-Path "$env:windir\System32\computecore.dll"
$r.hypervisorPresent = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent

Add-Type -Path (Join-Path $Dir 'hcs.cs')
$name = 'lab065-inner'
$work = Join-Path $Dir 'inner'
$null = New-Item -ItemType Directory -Force $work
$disk = Join-Path $work 'disk.vhdx'; $child = Join-Path $work 'child.vhdx'
$vmgs = Join-Path $work 'vm.vmgs'; $vmrs = Join-Path $work 'vm.vmrs'
$netId = [guid]'0651ab65-0000-4b0a-9a65-0650650650a2'; $epId = [guid]::NewGuid(); $mac = '00-15-5D-65-06-51'
$cs = [IntPtr]::Zero

Try-Step 'service.basic' { $x = [Hcs]::ServiceProperties($null); if ($x.Hr) { throw $x.ToString() }; $x.Doc }
Try-Step 'gpus' { @([Hcs]::PartitionableGpus()) }
Try-Step 'disk.diskpart' {
    $s = Join-Path $work 'dp.txt'
    Set-Content $s "create vdisk file=`"$disk`" maximum=2048 type=expandable`r`ncreate vdisk file=`"$child`" parent=`"$disk`""
    $out = diskpart /s $s | Out-String
    if (-not (Test-Path $child)) { throw $out }
    'base + child'
}
try {
    Try-Step 'state.files' {
        $a = [Hcs]::HcsCreateEmptyGuestStateFile($vmgs); $b = [Hcs]::HcsCreateEmptyRuntimeStateFile($vmrs)
        if ($a -or $b) { throw ('0x{0:X8} 0x{1:X8}' -f $a, $b) }; 'ok'
    }
    Try-Step 'access.grant' {
        foreach ($f in $child, $disk, $vmgs, $vmrs) { $hr = [Hcs]::HcsGrantVmAccess($name, $f); if ($hr) { throw ('{0} 0x{1:X8}' -f $f, $hr) } }; 'ok'
    }
    Try-Step 'hcn.network' {
        $j = [ordered]@{ SchemaVersion = @{ Major = 2; Minor = 0 }; Name = 'GpuVMLab065'; Type = 'ICS'; Flags = 11
            Ipams = @(@{ Type = 'Static'; Subnets = @(@{ IpAddressPrefix = '192.168.166.0/24'; Routes = @(@{ NextHop = '192.168.166.1'; DestinationPrefix = '0.0.0.0/0' }) }) }) } | ConvertTo-Json -Depth 10 -Compress
        $x = [Hcs]::CreateNetwork($netId, $j); if ($x.Hr) { throw $x.ToString() }; 'ok'
    }
    Try-Step 'hcn.endpoint' {
        $x = [Hcs]::CreateEndpoint($netId, $epId, (@{ SchemaVersion = @{ Major = 2; Minor = 0 }; HostComputeNetwork = "$netId"; MacAddress = $mac } | ConvertTo-Json -Compress))
        if ($x.Hr) { throw $x.ToString() }; 'ok'
    }
    $devices = [ordered]@{
        Scsi = [ordered]@{ Primary = [ordered]@{ Attachments = [ordered]@{ '0' = [ordered]@{ Type = 'VirtualDisk'; Path = $child } } } }
        VideoMonitor = [ordered]@{ HorizontalResolution = 1024; VerticalResolution = 768 }
        HvSocket = [ordered]@{ HvSocketConfig = [ordered]@{ ServiceTable = [ordered]@{} } }
        Keyboard = @{}; Mouse = @{}
    }
    if ($r['hcn.endpoint'].ok) { $devices.NetworkAdapters = [ordered]@{ Default = [ordered]@{ EndpointId = "$epId"; MacAddress = $mac } } }
    $cfg = [ordered]@{ SchemaVersion = [ordered]@{ Major = 2; Minor = 1 }; Owner = 'GpuVMLab065'; ShouldTerminateOnLastHandleClosed = $true
        VirtualMachine = [ordered]@{
            StopOnReset = $false
            Chipset = [ordered]@{ Uefi = [ordered]@{ Console = 'Default'; ApplySecureBootTemplate = 'Apply'; SecureBootTemplateId = '1734c6e8-3154-4dda-ba5f-a874cc483422' } }
            ComputeTopology = [ordered]@{ Memory = [ordered]@{ SizeInMB = 1024; AllowOvercommit = $true }; Processor = [ordered]@{ Count = 2 } }
            Devices = $devices
            GuestState = [ordered]@{ GuestStateFilePath = $vmgs; RuntimeStateFilePath = $vmrs } } } | ConvertTo-Json -Depth 20 -Compress
    Try-Step 'hcs.create' { $x = [Hcs]::Create($name, $cfg, [ref]$cs); if ($x.Hr) { throw $x.ToString() }; 'ok' }
    Try-Step 'hcs.start' { $x = [Hcs]::Start($cs); if ($x.Hr) { throw $x.ToString() }; 'ok' }
    if ($r['hcs.start'].ok) {
        Start-Sleep 20
        Try-Step 'hcs.runningAfter20s' { ([Hcs]::Properties($cs).Doc | ConvertFrom-Json).State }
        Try-Step 'hcs.gpuDefault' {
            $m = '{"ResourcePath":"VirtualMachine/ComputeTopology/Gpu","RequestType":"Update","Settings":{"AssignmentMode":"Default","AllowVendorExtension":true}}'
            $x = [Hcs]::Modify($cs, $m); if ($x.Hr) { throw $x.ToString() }; 'applied'
        }
        Try-Step 'hcs.terminate' { $x = [Hcs]::Terminate($cs); if ($x.Hr) { throw $x.ToString() }; 'ok' }
    }
} finally {
    if ($cs -ne [IntPtr]::Zero) { [Hcs]::Close($cs) }
    $r.cleanup = "ep=$([Hcs]::DeleteEndpoint($epId).Hr) net=$([Hcs]::DeleteNetwork($netId).Hr)"
    foreach ($f in $child, $disk, $vmgs, $vmrs) { $null = [Hcs]::HcsRevokeVmAccess($name, $f) }
    Start-Sleep 2
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
[pscustomobject]$r
