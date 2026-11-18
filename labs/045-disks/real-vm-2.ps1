# Lab 045, part 6: disposable machine and export/import on a real VM (follows real-vm.ps1, which leaves lab045-real
# and the template lab045-tpl). The disk-room check counts what every VM's disk may still grow into, so lab045-real
# itself is exported and removed first; then:
#   disposable  copy of lab045-tpl with -Disposable: start, open (new identity, pairs again), sweep while running
#               (kept), shut down, sweep (deleted, folder too)
#   import      the export imported back as lab045-real: fingerprint, new Sunshine identity and web login, open
#               (pairs through the new login)
# lab045-real (imported) and lab045-tpl are left for another session; -CleanAll removes them. Shuts win-gpu down
# cleanly and starts it again at the end. Takes the shared lab lock (queue-aware). Elevated PowerShell 7.
param([string]$Keep = 'win-gpu', [switch]$CleanAll)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lock.ps1')
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$m = Get-Module GpuVM
$out = Join-Path $PSScriptRoot 'out'
$stamp = Get-Date -Format yyyyMMdd-HHmmss
$stepLog = Join-Path $out "real2-steps-$stamp.log"
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

$name = 'lab045-real'
$tpl = 'lab045-tpl'
$work = Join-Path $env:TEMP 'lab045-real-export'
$exportFile = Join-Path $work 'lab045-real.gpuvm'
$keepWasRunning = $false
$disp = $null

Enter-LabLock 'disks-backup | lab 045 parte 2: desechable e importar en VM real (win-gpu apagada ~25 min)'
try {
    if (-not (Get-VM -Name $name -ErrorAction SilentlyContinue)) { throw "$name doesn't exist (run real-vm.ps1 first)." }
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory -Force $work | Out-Null
    # The guest password GpuVM keeps for lab045-real (DPAPI, this user) is needed again to import it.
    $cred = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $name
    $keepVm = Get-VM -Name $Keep -ErrorAction SilentlyContinue
    if ($keepVm -and $keepVm.State -ne 'Off') {
        $keepWasRunning = $true
        $t = Timed { Stop-VM -Name $Keep -Force }
        Note 'stop-win-gpu' @{ s = $t.s }
        Set-LabLockNote "$Keep APAGADA por disks-backup (vuelve a encenderse al terminar)"
    }
    StopClean $name
    $result.diskQuietMBps = Wait-DiskQuiet

    # ---- export a real machine, then remove it (its disk's possible growth would not leave room for a copy)
    $chain = & $m { param($p) Get-VhdChainBytes -Path $p } (Get-VMHardDiskDrive -VMName $name).Path
    $t = Timed { Export-GpuVM -Name $name -Path $exportFile -Confirm:$false }
    Note 'export (real Windows 10, Sunshine, paired)' @{ s = $t.s; sourceGB = [math]::Round($chain / 1GB, 2); fileGB = $t.r.sizeGB; freedGB = $t.r.freedGB }
    Remove-GpuVM -Name $name -DeleteDisk -Confirm:$false

    # ---- disposable copy of the template
    $t = Timed { New-GpuVM -Template $tpl -Disposable -Confirm:$false }
    $disp = $t.r.Name
    Note 'disposable create+start' @{ s = $t.s; name = $disp }
    $t = Timed { Connect-GpuVM -Name $disp -Viewer | Out-Null }
    Note 'disposable first open (new identity, pairs again)' @{ s = $t.s }
    $t = Timed { Connect-GpuVM -Name $disp -Viewer | Out-Null }
    Note 'disposable second open (warm)' @{ s = $t.s }
    Check 'running disposable is not swept' 0 @(Remove-GpuVMDisposable -Confirm:$false).Count
    StopClean $disp
    $t = Timed { @(Remove-GpuVMDisposable -Confirm:$false) }
    Note 'disposable sweep after shutdown' @{ s = $t.s; removed = ($t.r -join ',') }
    Check 'disposable VM gone' $false ([bool](Get-VM -Name $disp -ErrorAction SilentlyContinue))
    Check 'disposable folder gone' $false (Test-Path (Join-Path (& $m { Get-GpuVMDefaultRoot }) $disp))
    $disp = $null

    # ---- import it back
    $t = Timed { Import-GpuVM -Path $exportFile -Credential $cred -Confirm:$false | Out-Null }
    Note 'import' @{ s = $t.s }
    Check 'imported under its own name (free again)' $true ([bool](Get-VM -Name $name -ErrorAction SilentlyContinue))
    $st = & $m { param($n) Get-GpuVMState -Name $n } $name
    Check 'imported pairing not carried over' '' "$($st['streaming']['pairedClient'])"
    Start-VM -Name $name
    $t = Timed { Connect-GpuVM -Name $name -Viewer | Out-Null }
    $st = & $m { param($n) Get-GpuVMState -Name $n } $name
    Note 'import first open (new web login + identity, pairs)' @{ s = $t.s; paired = [bool]$st['streaming']['pairedClient'] }
    Check 'imported machine paired through its new web login' $true ([bool]$st['streaming']['pairedClient'])
    StopClean $name
}
catch {
    $result.error = "$($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)"
    Write-Warning $result.error
}
finally {
    Write-Host 'cleanup'
    if ($disp -and (Get-VM -Name $disp -ErrorAction SilentlyContinue)) { StopClean $disp; Remove-GpuVM -Name $disp -DeleteDisk -Confirm:$false }
    if ($CleanAll) {
        if (Get-VM -Name $name -ErrorAction SilentlyContinue) { StopClean $name; Remove-GpuVM -Name $name -DeleteDisk -Confirm:$false }
        try { Remove-GpuVMTemplate -Name $tpl -Confirm:$false } catch { Write-Warning $_.Exception.Message }
    }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    if ($keepWasRunning) { Set-LabLockNote "encendiendo $Keep"; try { Start-VM -Name $Keep; Note 'start-win-gpu' @{ ok = $true } } catch { Write-Warning "No se pudo encender ${Keep}: $($_.Exception.Message)" } }
    Exit-LabLock
    $global:GpuVMProgressSink = $null
    $result.failures = $failures
    $result.finishedAt = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out "real-vm-2-$stamp.json")
    Write-Host "failures: $failures"
}
