# Lab 045, part 5: the same features on a real VM that boots with the GPU.
# Shuts win-gpu down cleanly (Stop-VM) to free memory and starts it again at the end. It never deletes win-gpu or its
# disk. Its own test VM, lab045-real, is installed from the Windows ISO (4 GB, 4 threads). Steps:
#   open        Connect-GpuVM -Viewer: wait for Windows and Sunshine, then pair (no window opens)
#   points      point, marker written through PowerShell Direct, go back, boot, check the marker is gone and the pairing still works
#   template    template from lab045-real (with compaction): time and size against the source chain
#   disposable  disposable copy: start, open (new identity, so it pairs again), shut down, sweep, check it's gone
#   transfer    export lab045-real, import it (name taken -> lab045-real-2), open it (new web login and identity)
# Every Write-Step is timestamped into out/real-steps-*.log. Takes the shared lab lock. Elevated PowerShell 7.
param(
    [string]$IsoPath = 'C:\Users\you\Downloads\Win10_22H2_Spanish_Mexico_x64v1.iso',
    [string]$Keep = 'win-gpu'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lock.ps1')
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$m = Get-Module GpuVM
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null
$stamp = Get-Date -Format yyyyMMdd-HHmmss
$stepLog = Join-Path $out "real-steps-$stamp.log"
$global:GpuVMProgressSink = [scriptblock]::Create("param(`$msg) Add-Content -LiteralPath '$stepLog' -Value (""`$((Get-Date).ToString('HH:mm:ss.fff')) `$msg"")")
$result = [ordered]@{ startedAt = (Get-Date).ToString('o'); steps = [ordered]@{}; checks = [System.Collections.Generic.List[object]]::new() }
$failures = 0
function Note($k, $v) { $result.steps[$k] = $v; Write-Host ("{0,-34} {1}" -f $k, ($v | ConvertTo-Json -Compress -Depth 4)); Add-Content $stepLog "== $k $($v | ConvertTo-Json -Compress -Depth 4)" }
function Check($label, $expected, $actual) {
    $ok = "$expected" -eq "$actual"; if (-not $ok) { $script:failures++ }
    $result.checks.Add([ordered]@{ label = $label; ok = $ok; expected = "$expected"; actual = "$actual" })
    Write-Host ("{0,-50} {1,-5} expected={2} actual={3}" -f $label, $ok, $expected, $actual)
}
function Timed([scriptblock]$body) { $sw = [Diagnostics.Stopwatch]::StartNew(); $r = & $body; [pscustomobject]@{ r = $r; s = [math]::Round($sw.Elapsed.TotalSeconds, 1) } }
function StopClean($name) {
    $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
    if ($vm -and $vm.State -ne 'Off') { Stop-VM -Name $name -Force; }
}

$chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
$plain = -join (1..16 | ForEach-Object { $chars[[Security.Cryptography.RandomNumberGenerator]::GetInt32($chars.Length)] })
$cred = [pscredential]::new('gpuvm', (ConvertTo-SecureString $plain -AsPlainText -Force))
$name = 'lab045-real'
$tpl = 'lab045-tpl'
$exportFile = Join-Path $env:TEMP 'lab045-real.gpuvm'
$keepWasRunning = $false
$made = [System.Collections.Generic.List[string]]::new()

Enter-LabLock 'disks-backup | lab 045: VM real (win-gpu apagada ~40 min, la enciendo al terminar)'
try {
    foreach ($n in $name, "$name-2") { if (Get-VM -Name $n -ErrorAction SilentlyContinue) { throw "$n already exists." } }
    $keepVm = Get-VM -Name $Keep -ErrorAction SilentlyContinue
    if ($keepVm -and $keepVm.State -ne 'Off') {
        $keepWasRunning = $true
        $t = Timed { Stop-VM -Name $Keep -Force }
        Note 'stop-win-gpu' @{ s = $t.s }
        Set-LabLockNote "$Keep APAGADA por disks-backup (vuelve a encenderse al terminar)"
    }
    $result.diskQuietMBps = Wait-DiskQuiet

    # ---- create + first open
    $t = Timed { New-GpuVM -Name $name -IsoPath $IsoPath -Profile balanced -Credential $cred -Confirm:$false `
            -Override @{ vm = @{ memoryGB = 4; cpu = @{ count = 4 }; disk = @{ sizeGB = 64; type = 'Dynamic' } } } | Out-Null }
    $made.Add($name)
    Note 'create' @{ s = $t.s }
    $t = Timed { Connect-GpuVM -Name $name -Viewer | Out-Null }
    Note 'first-open' @{ s = $t.s; paired = [bool](& $m { param($n) (Get-GpuVMState -Name $n)['streaming']['pairedClient'] } $name) }
    $t = Timed { Connect-GpuVM -Name $name -Viewer | Out-Null }
    Note 'second-open (warm, baseline)' @{ s = $t.s }

    # ---- restore points with a real boot
    StopClean $name
    $t = Timed { New-GpuVMRestorePoint -Name $name -Label 'lab' -Confirm:$false }
    $pointId = $t.r.id
    Note 'point-create' @{ s = $t.s }
    Start-VM -Name $name
    $t = Timed { Connect-GpuVM -Name $name -Viewer | Out-Null }
    Note 'open-on-point' @{ s = $t.s }
    Invoke-Command -VMName $name -Credential $cred -ScriptBlock { New-Item -ItemType Directory -Force C:\GpuVM-lab | Out-Null; 'after-point' | Set-Content C:\GpuVM-lab\marker.txt }
    StopClean $name
    $t = Timed { Restore-GpuVMRestorePoint -Name $name -Id $pointId -Confirm:$false | Out-Null }
    Note 'point-restore' @{ s = $t.s }
    $t = Timed { Connect-GpuVM -Name $name -Viewer | Out-Null }
    Note 'open-after-restore (boot + still paired)' @{ s = $t.s }
    Check 'marker written after the point is gone' $false (Invoke-Command -VMName $name -Credential $cred -ScriptBlock { Test-Path C:\GpuVM-lab\marker.txt })
    Check 'GPU visible in the guest after going back' $true (Invoke-Command -VMName $name -Credential $cred -ScriptBlock { [bool](Get-CimInstance Win32_VideoController | Where-Object Name -match 'NVIDIA') })
    StopClean $name
    $t = Timed { Remove-GpuVMRestorePoint -Name $name -Id $pointId -Confirm:$false }
    Note 'point-delete (merge)' @{ s = $t.s }

    # ---- template (with compaction)
    $chain = & $m { param($p) Get-VhdChainBytes -Path $p } (Get-VMHardDiskDrive -VMName $name).Path
    $t = Timed { New-GpuVMTemplate -Name $tpl -VMName $name -Confirm:$false }
    $made.Add("template:$tpl")
    $tplFile = Join-Path (& $m { Get-TemplateRoot }) "$tpl\$tpl.vhdx"
    Note 'template' @{ s = $t.s; sourceChainGB = [math]::Round($chain / 1GB, 2); templateGB = [math]::Round((Get-Item $tplFile).Length / 1GB, 2) }

    # ---- disposable copy
    $t = Timed { New-GpuVM -Template $tpl -Disposable -Confirm:$false }
    $disp = $t.r.Name
    if (-not $disp) { $disp = (Get-VM | Where-Object Name -like "$tpl-desechable*" | Select-Object -First 1).Name }
    $made.Add($disp)
    Note 'disposable-create+start' @{ s = $t.s; name = $disp }
    $t = Timed { Connect-GpuVM -Name $disp -Viewer | Out-Null }
    Note 'disposable-first-open (new identity, pairs again)' @{ s = $t.s }
    Check 'disposable not swept while running' 0 @(Remove-GpuVMDisposable -Confirm:$false).Count
    StopClean $disp
    $t = Timed { @(Remove-GpuVMDisposable -Confirm:$false) }
    Note 'disposable-sweep' @{ s = $t.s; removed = ($t.r -join ',') }
    Check 'disposable VM gone' $false ([bool](Get-VM -Name $disp -ErrorAction SilentlyContinue))
    Check 'disposable folder gone' $false (Test-Path (Join-Path (& $m { Get-GpuVMDefaultRoot }) $disp))

    # ---- export + import
    if (Test-Path $exportFile) { Remove-Item $exportFile -Force }
    $t = Timed { Export-GpuVM -Name $name -Path $exportFile -Confirm:$false }
    Note 'export' @{ s = $t.s; fileGB = $t.r.sizeGB; freedGB = $t.r.freedGB; sourceChainGB = [math]::Round((& $m { param($p) Get-VhdChainBytes -Path $p } (Get-VMHardDiskDrive -VMName $name).Path) / 1GB, 2) }
    $t = Timed { Import-GpuVM -Path $exportFile -Credential $cred -Confirm:$false | Out-Null }
    $imp = "$name-2"; $made.Add($imp)
    Note 'import' @{ s = $t.s }
    Start-VM -Name $imp
    $t = Timed { Connect-GpuVM -Name $imp -Viewer | Out-Null }
    Note 'import-first-open (new web login + identity)' @{ s = $t.s; paired = [bool](& $m { param($n) (Get-GpuVMState -Name $n)['streaming']['pairedClient'] } $imp) }
    StopClean $imp
}
catch {
    $result.error = "$($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)"
    Write-Warning $result.error
}
finally {
    Write-Host 'cleanup'
    foreach ($n in @($made) | Where-Object { $_ -notlike 'template:*' }) {
        try { StopClean $n; if (Get-VM -Name $n -ErrorAction SilentlyContinue) { Remove-GpuVM -Name $n -DeleteDisk -Confirm:$false } } catch { Write-Warning "cleanup ${n}: $($_.Exception.Message)" }
        $d = Join-Path (& $m { Get-GpuVMDefaultRoot }) $n
        if (Test-Path $d) { Get-ChildItem $d -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }; Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if ($made -contains "template:$tpl") { try { Remove-GpuVMTemplate -Name $tpl -Confirm:$false } catch { Write-Warning "cleanup template: $($_.Exception.Message)" } }
    if (Test-Path $exportFile) { Remove-Item $exportFile -Force }
    if ($keepWasRunning) { Set-LabLockNote "encendiendo $Keep"; try { Start-VM -Name $Keep; Note 'start-win-gpu' @{ ok = $true } } catch { Write-Warning "No se pudo encender ${Keep}: $($_.Exception.Message)" } }
    Exit-LabLock
    $global:GpuVMProgressSink = $null
    $result.failures = $failures
    $result.finishedAt = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out "real-vm-$stamp.json")
    Write-Host "failures: $failures"
}
