# Lab 045, part 4: export to one .gpuvm file and import it back, on a throwaway VM that never boots.
# The VM sits on a Windows base with a restore point on top, a kept file, a deleted file (space to give back) and a
# fake Sunshine identity. Measures export time and size per compression, then imports (name taken -> "-2"), checks
# the disk fingerprint, the content, the new streaming identity and web login, and that a tampered file is refused
# and leaves nothing behind. Takes the shared lab lock (it moves GBs on C:). Elevated PowerShell 7.
param(
    # A never-booted Windows base if there is one, else lab045-tpl's disk (any Windows disk works as a parent).
    [string]$Parent = $(@(Get-ChildItem 'C:\GpuVM\.bases\*\base.vhdx', 'C:\GpuVM\.templates\lab045-tpl\lab045-tpl.vhdx' -ErrorAction SilentlyContinue)[0].FullName),
    [int]$KeepGB = 2,
    [int]$WasteGB = 4,
    [string[]]$Compressions = @('NoCompression', 'Fastest')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lock.ps1')
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$m = Get-Module GpuVM
$name = 'lab045-xf'
$root = & $m { Get-GpuVMDefaultRoot }
# Outside GpuVM's folder: Export-GpuVM refuses to write inside it.
$work = Join-Path $(if ($env:LAB045_WORKDIR) { $env:LAB045_WORKDIR } else { $env:TEMP }) 'lab045-xfer-files'
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null
$result = [ordered]@{ startedAt = (Get-Date).ToString('o'); keepGB = $KeepGB; wasteGB = $WasteGB
    exports = [System.Collections.Generic.List[object]]::new(); checks = [System.Collections.Generic.List[object]]::new() }
$failures = 0
function Check($label, $expected, $actual) {
    $ok = "$expected" -eq "$actual"; if (-not $ok) { $script:failures++ }
    $result.checks.Add([ordered]@{ label = $label; ok = $ok; expected = "$expected"; actual = "$actual" })
    Write-Host ("{0,-52} {1,-5} expected={2} actual={3}" -f $label, $ok, $expected, $actual)
}
# $body is created here, so it runs in this script's scope (sees its variables) even when the module calls it.
function InGuest($vm, [scriptblock]$body) {
    $disk = (Get-VMHardDiskDrive -VMName $vm).Path
    & $m { param($disk, $body) Invoke-WithMountedWindows -Path $disk -ScriptBlock $body } $disk $body
}
function Fill($path, $gb) {
    $buf = [byte[]]::new(16MB); $rng = [Random]::new(7)
    $fs = [IO.File]::Create($path)
    try { for ($i = 0; $i -lt $gb * 64; $i++) { $rng.NextBytes($buf); $fs.Write($buf, 0, $buf.Length) } } finally { $fs.Dispose() }
}
$importedNames = [System.Collections.Generic.List[string]]::new()

Enter-LabLock 'disks-backup | lab 045: export/import offline (moves ~20 GB on C:)'
try {
    $result.diskQuietMBps = Wait-DiskQuiet
    if (Get-VM -Name $name -ErrorAction SilentlyContinue) { throw "$name already exists." }
    # Files left by an interrupted run would make Export-GpuVM refuse to overwrite them.
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory -Force $work | Out-Null
    $vmDir = Join-Path $root $name
    $vhd = Join-Path $vmDir "Virtual Hard Disks\$name.vhdx"
    New-Item -ItemType Directory -Force (Split-Path $vhd) | Out-Null
    New-VHD -Path $vhd -ParentPath $Parent -Differencing | Out-Null
    New-VM -Name $name -Generation 2 -MemoryStartupBytes 2GB -VHDPath $vhd -Path $root | Out-Null
    Add-VMGpuPartitionAdapter -VMName $name
    $state = [ordered]@{ name = $name; backend = 'hyperv-gpup'; profile = 'balanced'; vmDir = $vmDir; vhdPath = $vhd; statePath = Join-Path $vmDir 'gpuvm.json'
        config = (& $m { Resolve-GpuVMProfile -Name balanced }); edition = 'Windows 10 Pro'; installedApps = @('vlc'); pendingApps = @()
        gpu = [ordered]@{ name = 'lab'; driverVersion = '32.0.16.1088' }
        guest = [ordered]@{ user = 'gpuvm'; password = (ConvertTo-SecureString 'lab-only' -AsPlainText -Force | ConvertFrom-SecureString) }
        streaming = [ordered]@{ provider = 'sunshine'; user = 'gpuvm'; password = 'dpapi-blob'; pairedClient = 'lab' } }
    & $m { param($s) Save-GpuVMState $s } $state

    # Guest content: a fake Sunshine identity, a deleted file, then a restore point and a kept file on top of it.
    InGuest $name {
        param($r)
        $cfg = Join-Path $r 'Program Files\Sunshine\config'
        New-Item -ItemType Directory -Force (Join-Path $cfg 'credentials') | Out-Null
        [IO.File]::WriteAllText((Join-Path $cfg 'sunshine_state.json'), '{"root":{"uniqueid":"LAB-ID","named_devices":[]},"username":"old","salt":"x","password":"y"}')
        'cert' | Set-Content (Join-Path $cfg 'credentials\cacert.pem'); 'key' | Set-Content (Join-Path $cfg 'credentials\cakey.pem')
        Fill (Join-Path $r 'lab045-waste.bin') $WasteGB
        Remove-Item (Join-Path $r 'lab045-waste.bin')
    }
    New-GpuVMRestorePoint -Name $name -Label 'lab' -Confirm:$false | Out-Null
    InGuest $name { param($r) Fill (Join-Path $r 'lab045-keep.bin') $KeepGB; [IO.File]::WriteAllText((Join-Path $r 'lab045-marker.txt'), 'export-me') }
    $result.sourceChainGB = [math]::Round((& $m { param($p) Get-VhdChainBytes -Path $p } $vhd) / 1GB, 2)
    $keepHash = (InGuest $name { param($r) (Get-FileHash (Join-Path $r 'lab045-keep.bin')).Hash })

    $files = @{}
    foreach ($compression in $Compressions) {
        $target = Join-Path $work "$name-$compression.gpuvm"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $e = Export-GpuVM -Name $name -Path $target -Compression $compression -Confirm:$false
        $row = [ordered]@{ compression = $compression; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); fileGB = $e.sizeGB; diskGB = $e.diskGB; freedGB = $e.freedGB }
        $result.exports.Add($row); Write-Host ($row | ConvertTo-Json -Compress)
        $files[$compression] = $target
    }
    $zip = [IO.Compression.ZipFile]::OpenRead($files['NoCompression'])
    try {
        $r = [IO.StreamReader]::new($zip.GetEntry('manifest.json').Open()); $manifestText = $r.ReadToEnd(); $r.Dispose()
    } finally { $zip.Dispose() }
    Check 'manifest has no DPAPI blobs or paths' $false ($manifestText -match 'password|dpapi|01000000d08c9ddf|GpuVM\\\\lab045')
    Check 'source VM still has its point' 1 @((Get-GpuVMRestorePoint -Name $name).points).Count

    # The source VM reserves its disk's full size, which would leave no room for the import: it is removed, and an
    # empty folder with its name keeps the name taken.
    Remove-VM -Name $name -Force
    Get-ChildItem $vmDir -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item $vmDir -Recurse -Force
    New-Item -ItemType Directory $vmDir | Out-Null
    # Import with the name taken: it must become "<name>-2".
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $cred = [pscredential]::new('gpuvm', (ConvertTo-SecureString 'lab-only' -AsPlainText -Force))
    $imp = Import-GpuVM -Path $files['NoCompression'] -Credential $cred -Override @{ vm = @{ memoryGB = 4 } } -Confirm:$false
    $result.importSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $newName = "$name-2"; $importedNames.Add($newName)
    Check 'imported under a free name' $true ([bool](Get-VM -Name $newName -ErrorAction SilentlyContinue))
    $newDisk = (Get-VMHardDiskDrive -VMName $newName).Path
    Check 'imported disk stands alone' 'Dynamic' (Get-VHD $newDisk).VhdType
    Check 'GPU partition on imported VM' 1 @(Get-VMGpuPartitionAdapter -VMName $newName).Count
    $inside = InGuest $newName {
        param($r)
        $cfg = Join-Path $r 'Program Files\Sunshine\config'
        $s = Get-Content -Raw (Join-Path $cfg 'sunshine_state.json') | ConvertFrom-Json -AsHashtable
        [ordered]@{ marker = (Get-Content -Raw (Join-Path $r 'lab045-marker.txt')); keep = (Get-FileHash (Join-Path $r 'lab045-keep.bin')).Hash
            root = $s.Contains('root'); user = $s['username']; salt = "$($s['salt'])".Length; hash = "$($s['password'])"
            pem = (Test-Path (Join-Path $cfg 'credentials\cacert.pem')) }
    }
    Check 'marker came along' 'export-me' $inside.marker
    Check 'kept file intact (SHA-256)' $keepHash $inside.keep
    # Import never touches the file's disk (it came from outside): the identity is reset inside the VM on its first
    # open (real-vm-3.ps1). Here: still the exported identity, and the machine marked for the reset.
    Check 'imported disk not modified (old identity still there)' $true $inside.root
    $st = & $m { param($n) Get-GpuVMState -Name $n } $newName
    Check 'marked to reset its identity on first open' $true ([bool]$st['pendingIdentityReset'])
    Check 'new web login saved for the reset (DPAPI)' $true ([bool]$st['streaming']['password'] -and $st['streaming']['password'] -ne 'dpapi-blob')
    Check 'guest password saved (DPAPI, this PC)' 'lab-only' ([pscredential]::new('x', (ConvertTo-SecureString $st['guest']['password'])).GetNetworkCredential().Password)
    Check 'pairing not carried over' '' "$($st['streaming']['pairedClient'])"
    Check 'apps came along' 'vlc' ($st['installedApps'] -join ',')
    Check 'renamed on first open' $true $st['pendingRename']

    # The first import reserves its disk's full size: it goes first, so the next refusal can only be the fingerprint.
    Remove-GpuVM -Name $newName -DeleteDisk -Confirm:$false
    # Tampered file: the manifest's fingerprint no longer matches the disk.
    $bad = Join-Path $work 'tampered.gpuvm'
    Copy-Item $files['Fastest'] $bad
    $zip = [IO.Compression.ZipFile]::Open($bad, 'Update')
    try {
        $entry = $zip.GetEntry('manifest.json'); $r = [IO.StreamReader]::new($entry.Open()); $text = $r.ReadToEnd(); $r.Dispose(); $entry.Delete()
        $text = $text -replace '"sha256": "[0-9a-f]{64}"', ('"sha256": "' + ('0' * 64) + '"')
        $w = [IO.StreamWriter]::new($zip.CreateEntry('manifest.json').Open()); $w.Write($text); $w.Dispose()
    } finally { $zip.Dispose() }
    $err = $null
    try { Import-GpuVM -Path $bad -Name 'lab045-bad' -Credential $cred -Confirm:$false | Out-Null } catch { $err = $_.Exception.Message }
    Check 'tampered file refused' $true ($err -match 'huella')
    Check 'nothing left after refusal' $false ((Test-Path (Join-Path $root 'lab045-bad')) -or [bool](Get-VM -Name 'lab045-bad' -ErrorAction SilentlyContinue))
    $err = $null
    try { Import-GpuVM -Path (Join-Path $work 'nope.gpuvm') -Credential $cred -Confirm:$false | Out-Null } catch { $err = $_.Exception.Message }
    Check 'missing file says so' $true ($err -match 'No existe')
}
finally {
    foreach ($n in @($name) + $importedNames + @('lab045-bad')) {
        if (Get-VM -Name $n -ErrorAction SilentlyContinue) { Remove-VM -Name $n -Force }
        $d = Join-Path $root $n
        if (Test-Path $d) { Get-ChildItem $d -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }; Remove-Item $d -Recurse -Force }
    }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    Exit-LabLock
    $result.failures = $failures
    $result.finishedAt = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out "transfer-offline-$(Get-Date -Format yyyyMMdd-HHmmss).json")
    Write-Host "failures: $failures"
}
