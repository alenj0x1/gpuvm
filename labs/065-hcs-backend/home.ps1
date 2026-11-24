# Lab 065, Windows Home: does HCS work on an edition without Hyper-V? Creates a Windows 10 Home machine with GpuVM
# (Hyper-V, no GPU, nested virtualization), turns on only "Virtual Machine Platform" inside it, and runs home-probe.ps1
# there (HCS VM + HCN network + diskpart disks, no Hyper-V module). Holds C:\GpuVM\.lab-lock for the whole chain and
# deletes the machine, its disk and the Home base it made at the end. ~25-35 min. Needs an elevated shell.
#   pwsh -NoProfile -File labs/065-hcs-backend/home.ps1 [-Keep]
param([string]$IsoPath = (Get-Content (Join-Path $PSScriptRoot '..\..\isos.json') -Raw | ConvertFrom-Json).isos[0].path,
    [string]$Edition = 'Windows 10 Home', [int]$MemoryGB = 6, [switch]$Keep)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = $PSScriptRoot
$name = 'lab065-home'
$lock = 'C:\GpuVM\.lab-lock'
$outDir = Join-Path $here 'out'; $null = New-Item -ItemType Directory -Force $outDir
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-home'
$res = [ordered]@{ runId = $runId; edition = $Edition; steps = [ordered]@{} }
$sw = [Diagnostics.Stopwatch]::StartNew()
function Log([string]$m) { Write-Host ("[{0,7:n1}s] {1}" -f $sw.Elapsed.TotalSeconds, $m) }
function Step([string]$Key, [scriptblock]$Body) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    try { $v = & $Body; $res.steps[$Key] = [ordered]@{ ok = $true; sec = [math]::Round($t.Elapsed.TotalSeconds, 1) }; Log "$Key ok ($([math]::Round($t.Elapsed.TotalSeconds,1)) s)"; $v }
    catch { $res.steps[$Key] = [ordered]@{ ok = $false; sec = [math]::Round($t.Elapsed.TotalSeconds, 1); error = "$_" }; Log "$Key FAILED: $_"; throw }
}
function Wait-Direct([pscredential]$Cred, [int]$TimeoutSec) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    while ($t.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if ((Get-VM -Name $name).State -ne 'Running') { throw "The machine is $((Get-VM -Name $name).State)." }
        try { $null = Invoke-Command -VMName $name -Credential $Cred -ScriptBlock { 1 } -ErrorAction Stop; return [math]::Round($t.Elapsed.TotalSeconds, 1) } catch { Start-Sleep 5 }
    }
    throw "No PowerShell Direct after $TimeoutSec s."
}

Import-Module (Join-Path $here '..\..\src\GpuVM\GpuVM.psd1') -Force
if (-not (Test-Path $IsoPath)) { throw "No ISO at $IsoPath" }
if (Get-VM -Name $name -ErrorAction SilentlyContinue) { throw "$name already exists." }
$freeGB = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
if ($freeGB -lt $MemoryGB + 1) { throw "Only $([math]::Round($freeGB,1)) GB free, need $($MemoryGB + 1)." }
$basesBefore = @(Get-ChildItem C:\GpuVM\.bases -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)

try { $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) }
catch [IO.IOException] { throw "The lab lock is held: $(Get-Content $lock -Raw)" }
$fs.Write([Text.Encoding]::UTF8.GetBytes("lab065-home pid=$PID $(Get-Date -Format o)")); $fs.Close()

$pw = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 20 | ForEach-Object { [char]$_ })
$cred = [pscredential]::new('labuser', (ConvertTo-SecureString $pw -AsPlainText -Force))
try {
    Step 'vm.create' { New-GpuVM -Name $name -IsoPath $IsoPath -Edition $Edition -Credential $cred -Confirm:$false | Out-Null }
    Step 'vm.configure' {
        if ((Get-VM $name).State -ne 'Off') { Stop-VM $name -Force -TurnOff }
        Get-VMGpuPartitionAdapter -VMName $name -ErrorAction SilentlyContinue | Remove-VMGpuPartitionAdapter
        Set-VMMemory $name -DynamicMemoryEnabled $false -StartupBytes ([int64]$MemoryGB * 1GB)
        Set-VMProcessor $name -ExposeVirtualizationExtensions $true -Count 4
        Start-VM $name
    }
    $res.firstBootToDirectSec = Step 'guest.setup' { Wait-Direct $cred 1800 }
    $res.gpuvmSetupSec = Step 'guest.gpuvmSetupDone' {
        $t = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Invoke-Command -VMName $name -Credential $cred -ScriptBlock { Test-Path C:\GpuVM\setup.done.json } -ErrorAction SilentlyContinue)) {
            if ($t.Elapsed.TotalSeconds -gt 1500) { throw 'GpuVM guest setup did not finish in 25 min.' }
            if ((Get-VM -Name $name).State -ne 'Running') { throw "The machine is $((Get-VM -Name $name).State)." }
            Start-Sleep 10
        }
        $done = Invoke-Command -VMName $name -Credential $cred -ScriptBlock {
            [ordered]@{ pending = (Get-Content C:\GpuVM\setup.done.json -Raw | ConvertFrom-Json).rebootPending; boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime } }
        $res.gpuvmSetupRebootPending = $done.pending
        if ($done.pending) {
            while ($true) {
                if ($t.Elapsed.TotalSeconds -gt 2400) { throw 'GpuVM setup restart did not come back.' }
                Start-Sleep 5
                if ((Get-VM -Name $name).State -eq 'Off') { Start-VM $name }
                try { $b = Invoke-Command -VMName $name -Credential $cred -ScriptBlock { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime } -ErrorAction Stop; if ($b -gt $done.boot) { break } } catch {}
            }
            Start-Sleep 20
        }
        [math]::Round($t.Elapsed.TotalSeconds, 1)
    }
    $res.before = Step 'guest.edition' {
        Invoke-Command -VMName $name -Credential $cred -ScriptBlock {
            [ordered]@{ caption = (Get-CimInstance Win32_OperatingSystem).Caption
                hyperVFeature = @(Get-WindowsOptionalFeature -Online | Where-Object FeatureName -match '^Microsoft-Hyper-V' | ForEach-Object { "$($_.FeatureName)=$($_.State)" })
                vmp = "$((Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform).State)" } }
    }
    $bootBefore = Step 'guest.enableVmp' {
        $b = Invoke-Command -VMName $name -Credential $cred -ScriptBlock {
            shutdown.exe /a 2>$null
            $null = Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart -WarningAction SilentlyContinue
            (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        }
        try { Invoke-Command -VMName $name -Credential $cred -ScriptBlock { Start-Process shutdown.exe -ArgumentList '/r /t 2 /f' } -ErrorAction Stop } catch {}
        $b
    }
    $res.restartToDirectSec = Step 'guest.restart' {
        $t = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            if ($t.Elapsed.TotalSeconds -gt 900) { throw 'The guest did not come back with a new boot in 900 s.' }
            Start-Sleep 5
            if ((Get-VM -Name $name).State -eq 'Off') { $res.offDuringRestart = $true; Start-VM $name }
            try {
                $boot = Invoke-Command -VMName $name -Credential $cred -ScriptBlock { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime } -ErrorAction Stop
                if ($boot -gt $bootBefore) { break }
            } catch {}
        }
        Start-Sleep 15
        [math]::Round($t.Elapsed.TotalSeconds, 1)
    }
    $res.probe = Step 'guest.probe' {
        $s = New-PSSession -VMName $name -Credential $cred
        try {
            Invoke-Command -Session $s -ScriptBlock { $null = New-Item -ItemType Directory -Force C:\GpuVMLab065 }
            Copy-Item (Join-Path $here 'hcs.cs') -Destination C:\GpuVMLab065\hcs.cs -ToSession $s
            Invoke-Command -Session $s -FilePath (Join-Path $here 'home-probe.ps1')
        } finally { Remove-PSSession $s -ErrorAction SilentlyContinue }
    }
} catch {
    $res.failure = "$_"
    try {
        $res.vmStateAfterFailure = "$((Get-VM -Name $name).State)"
        $null = Wait-Direct $cred 600
        $res.afterFailure = Invoke-Command -VMName $name -Credential $cred -ScriptBlock {
            [ordered]@{ boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')
                progress = Get-Content C:\GpuVMLab065\progress.txt -ErrorAction SilentlyContinue
                events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = (Get-Date).AddMinutes(-20) } -ErrorAction SilentlyContinue |
                    Where-Object { $_.Level -le 2 -or $_.Id -in 41, 1001, 6008, 1074 } | Select-Object -First 30 |
                    ForEach-Object { '{0:HH:mm:ss} {1} {2} {3}' -f $_.TimeCreated, $_.ProviderName, $_.Id, ("$($_.Message)" -split "`n")[0] }) }
        }
    } catch { $res.afterFailureError = "$_" }
    throw
} finally {
    $res.totalSec = [math]::Round($sw.Elapsed.TotalSeconds)
    if (-not $Keep) {
        try {
            if (Get-VM -Name $name -ErrorAction SilentlyContinue) { Stop-VM $name -Force -TurnOff -ErrorAction SilentlyContinue; Remove-GpuVM -Name $name -DeleteDisk -Confirm:$false }
            foreach ($b in @(Get-ChildItem C:\GpuVM\.bases -Directory -ErrorAction SilentlyContinue | Where-Object Name -notin $basesBefore)) {
                Remove-Item $b.FullName -Recurse -Force; $res.removedBase = $b.Name
            }
        } catch { $res.cleanupError = "$_" }
    }
    $res | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $outDir "$runId.json")
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
    Log "done -> out/$runId.json; left behind: vm=$([bool](Get-VM -Name $name -ErrorAction SilentlyContinue)) lock=$(Test-Path $lock)"
}
