# Lab 045, part 7: disposable machine and export/import on a real VM, with disposables reserving a fixed 20 GB.
#   disposable  copy of lab045-tpl with -Disposable: start, open (new identity, pairs again), not swept while on
#   export      the disposable machine, off, to one file (a real Windows 10 with Sunshine)
#   sweep       deletes the disposable machine and its folder
#   import      the file as lab045-imp: fingerprint, new Sunshine identity and web login, open (pairs through it)
# Everything it makes is deleted at the end (lab045-tpl stays). win-gpu is shut down cleanly and started again.
# Takes the shared lab lock (queue-aware). Elevated PowerShell 7.
param([string]$Keep = 'win-gpu', [string]$Template = 'lab045-tpl')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lock.ps1')
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$m = Get-Module GpuVM
$out = Join-Path $PSScriptRoot 'out'
$stamp = Get-Date -Format yyyyMMdd-HHmmss
$stepLog = Join-Path $out "real3-steps-$stamp.log"
$global:GpuVMProgressSink = [scriptblock]::Create("param(`$msg) Add-Content -LiteralPath '$stepLog' -Value (""`$((Get-Date).ToString('HH:mm:ss.fff')) `$msg"")")
$result = [ordered]@{ startedAt = (Get-Date).ToString('o'); steps = [ordered]@{}; checks = [System.Collections.Generic.List[object]]::new() }
$failures = 0
function Note($k, $v) { $result.steps[$k] = $v; Write-Host ("{0,-46} {1}" -f $k, ($v | ConvertTo-Json -Compress -Depth 4)); Add-Content $stepLog "== $k $($v | ConvertTo-Json -Compress -Depth 4)" }
function Check($label, $expected, $actual) {
    $ok = "$expected" -eq "$actual"; if (-not $ok) { $script:failures++ }
    $result.checks.Add([ordered]@{ label = $label; ok = $ok; expected = "$expected"; actual = "$actual" })
    Write-Host ("{0,-50} {1,-5} expected={2} actual={3}" -f $label, $ok, $expected, $actual)
}
function Timed([scriptblock]$body) { $sw = [Diagnostics.Stopwatch]::StartNew(); $r = & $body; [pscustomobject]@{ r = $r; s = [math]::Round($sw.Elapsed.TotalSeconds, 1) } }
function StopClean($n) { $vm = Get-VM -Name $n -ErrorAction SilentlyContinue; if ($vm -and $vm.State -ne 'Off') { Stop-VM -Name $n -Force } }

$imp = 'lab045-imp'
# Another drive when LAB045_WORKDIR says so: the export file on C: would take the room the import needs.
$work = Join-Path $(if ($env:LAB045_WORKDIR) { $env:LAB045_WORKDIR } else { $env:TEMP }) 'lab045-real3'
$exportFile = Join-Path $work 'disposable.gpuvm'
$keepWasRunning = $false
$disp = $null

Enter-LabLock 'disks-backup | lab 045 parte 3: desechable, exportar e importar en VM real (win-gpu apagada ~25 min)'
try {
    if (Get-VM -Name $imp -ErrorAction SilentlyContinue) { throw "$imp already exists." }
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory -Force $work | Out-Null
    $cred = & $m { param($t) $tp = Read-GpuVMTemplate -Name $t; [pscredential]::new($tp['guest']['user'], (ConvertTo-SecureString $tp['guest']['password'])) } $Template
    $keepVm = Get-VM -Name $Keep -ErrorAction SilentlyContinue
    if ($keepVm -and $keepVm.State -ne 'Off') {
        $keepWasRunning = $true
        $t = Timed { Stop-VM -Name $Keep -Force }
        Note 'stop-win-gpu' @{ s = $t.s }
        Set-LabLockNote "$Keep APAGADA por disks-backup (vuelve a encenderse al terminar)"
    }
    $result.diskQuietMBps = Wait-DiskQuiet
    $budget = & $m { $script:DiskCache = $null; Get-GpuVMDiskBudget -Root (Get-GpuVMDefaultRoot) }
    Note 'disk room before' @{ freeGB = $budget['freeGB']; promisedGB = $budget['promisedGB']; availableGB = $budget['availableGB'] }

    $t = Timed { New-GpuVM -Template $Template -Disposable -Confirm:$false }
    $disp = $t.r.Name
    Note 'disposable create+start' @{ s = $t.s; name = $disp }
    $budget = & $m { $script:DiskCache = $null; Get-GpuVMDiskBudget -Root (Get-GpuVMDefaultRoot) }
    Note 'disk room with the disposable on' @{ promisedGB = $budget['promisedGB']; availableGB = $budget['availableGB'] }
    $t = Timed { Connect-GpuVM -Name $disp -Viewer | Out-Null }
    Note 'disposable first open (new identity, pairs again)' @{ s = $t.s }
    $t = Timed { Connect-GpuVM -Name $disp -Viewer | Out-Null }
    Note 'disposable second open (warm)' @{ s = $t.s }
    Check 'running disposable is not swept' 0 @(Remove-GpuVMDisposable -Confirm:$false).Count
    StopClean $disp

    $chain = & $m { param($p) Get-VhdChainBytes -Path $p } (Get-VMHardDiskDrive -VMName $disp).Path
    $t = Timed { Export-GpuVM -Name $disp -Path $exportFile -Confirm:$false }
    Note 'export (real Windows 10: template + its copy merged)' @{ s = $t.s; chainGB = [math]::Round($chain / 1GB, 2); fileGB = $t.r.sizeGB; freedGB = $t.r.freedGB }

    $t = Timed { @(Remove-GpuVMDisposable -Confirm:$false) }
    Note 'disposable sweep after shutdown' @{ s = $t.s; removed = ($t.r -join ',') }
    Check 'disposable VM gone' $false ([bool](Get-VM -Name $disp -ErrorAction SilentlyContinue))
    Check 'disposable folder gone' $false (Test-Path (Join-Path (& $m { Get-GpuVMDefaultRoot }) $disp))
    $disp = $null

    $t = Timed { Import-GpuVM -Path $exportFile -Name $imp -Credential $cred -Confirm:$false | Out-Null }
    Note 'import' @{ s = $t.s }
    $st = & $m { param($n) Get-GpuVMState -Name $n } $imp
    Check 'imported pairing not carried over' '' "$($st['streaming']['pairedClient'])"
    Start-VM -Name $imp
    $t = Timed { Connect-GpuVM -Name $imp -Viewer | Out-Null }
    $st = & $m { param($n) Get-GpuVMState -Name $n } $imp
    Note 'import first open (new web login + identity, pairs)' @{ s = $t.s }
    Check 'imported machine paired through its new web login' $true ([bool]$st['streaming']['pairedClient'])
    StopClean $imp
}
catch {
    $result.error = "$($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)"
    Write-Warning $result.error
}
finally {
    Write-Host 'cleanup'
    foreach ($n in @($disp, $imp) | Where-Object { $_ }) {
        if (Get-VM -Name $n -ErrorAction SilentlyContinue) { try { StopClean $n; Remove-GpuVM -Name $n -DeleteDisk -Confirm:$false } catch { Write-Warning "cleanup ${n}: $($_.Exception.Message)" } }
    }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    if ($keepWasRunning) { Set-LabLockNote "encendiendo $Keep"; try { Start-VM -Name $Keep; Note 'start-win-gpu' @{ ok = $true } } catch { Write-Warning "No se pudo encender ${Keep}: $($_.Exception.Message)" } }
    Exit-LabLock
    $global:GpuVMProgressSink = $null
    $result.failures = $failures
    $result.finishedAt = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out "real-vm-3-$stamp.json")
    Write-Host "failures: $failures"
}
