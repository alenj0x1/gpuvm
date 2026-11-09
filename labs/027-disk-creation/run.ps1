# Lab 027: how long creating a VM takes and how much the host suffers meanwhile, before and after the change
# (Windows applied once to a base disk and copied, heavy work at low priority, disks mounted without a letter).
#   old       the module at HEAD (git), applying the ISO with DISM at normal priority, as before
#   new-cold  the working tree's module with no base yet: it applies the ISO once into the base, then copies it
#   new-warm  the working tree's module with the base ready: only the copy
# tools/host-probe/probe.ps1 runs the whole time at normal priority and times CPU work, a flushed write and an
# uncached read every 200 ms; the summary slices it by phase (idle before, each variant, and a 30 s cool-down).
# At the end the last VM is booted to check the copy works (Windows ready, C: grown to the profile's size) and,
# with -DiskLab, lab 028 runs on it. Every VM, disk and file made here is removed in finally.
# Run elevated (PowerShell 7), with Hyper-V idle:  pwsh -File labs/027-disk-creation/run.ps1 -DiskLab
param(
    [string]$IsoPath,
    [string]$Profile = 'balanced',
    # The lab VMs only need to boot: less memory than the profile so they fit next to the user's programs.
    [int]$MemoryGB = 4,
    [string[]]$Variants = @('old', 'new-cold', 'new-warm', 'new-warm'),
    [switch]$SkipBoot,
    [switch]$DiskLab,
    # Deletes this ISO's base first (one an earlier run of this lab made), so new-cold measures the first time again.
    [switch]$FreshBase,
    [int]$IdleSec = 60,
    # Long enough for the SSD to empty its fast cache between variants (lab 027: it decides the stalls).
    [int]$CooldownSec = 90
)
$ErrorActionPreference = 'Stop'
# pwsh -File passes "a,b" as one string.
$Variants = @($Variants | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$out = Join-Path $PSScriptRoot "out\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Force $out | Out-Null
Start-Transcript -Path (Join-Path $out 'transcript.log') | Out-Null
$newModule = Join-Path $repo 'src\GpuVM\GpuVM.psd1'
$m = Import-Module $newModule -Force -PassThru

function Say([string]$text) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $text" -ForegroundColor Cyan }
$phases = [System.Collections.Generic.List[object]]::new()
function Mark([string]$name, [datetime]$start, [hashtable]$extra = @{}) {
    $entry = [ordered]@{ phase = $name; start = $start.ToString('o'); end = (Get-Date).ToString('o') }
    foreach ($k in $extra.Keys) { $entry[$k] = $extra[$k] }
    $phases.Add($entry)
}

# ---- Preflight: fail before the long part.
if (-not (& $m { Test-IsAdmin })) { throw 'Corre el lab elevado.' }
if (-not $IsoPath) { $IsoPath = (& $m { Read-IsoLibrary } | Where-Object { Test-Path -LiteralPath $_['path'] } | Select-Object -First 1)['path'] }
# Run from the repo, the module keeps its data in the repo; the installed app's ISO list is in ProgramData.
if (-not $IsoPath) {
    $installed = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'GpuVM\isos.json'
    if (Test-Path $installed) { $IsoPath = @((Get-Content -Raw $installed | ConvertFrom-Json).isos | Where-Object { Test-Path -LiteralPath $_.path } | Select-Object -First 1).path }
}
if (-not $IsoPath -or -not (Test-Path -LiteralPath $IsoPath)) { throw 'No hay ISO: pasa -IsoPath.' }
$root = & $m { Get-GpuVMDefaultRoot }
$freeGB = & $m { param($r) Get-DriveFreeGB $r } $root
Say "ISO $IsoPath; $freeGB GB libres en $root"
if ($freeGB -lt 45) { throw "Hacen falta unos 45 GB libres (base + una VM a la vez); hay $freeGB." }
if (Get-VM -Name 'lab027-*' -ErrorAction SilentlyContinue) { throw 'Quedan VMs lab027-* de una corrida anterior; bórralas primero.' }

# The module as it was before the change, from git.
$baseline = Join-Path $out 'baseline'
New-Item -ItemType Directory -Force $baseline | Out-Null
$tar = Join-Path $out 'baseline.tar'
& git -C $repo archive -o $tar HEAD src guest profiles templates streaming apps
if ($LASTEXITCODE) { throw 'No se pudo sacar el módulo de HEAD.' }
& tar -x -f $tar -C $baseline
if ($LASTEXITCODE) { throw 'No se pudo extraer el módulo de HEAD.' }
Remove-Item $tar
$oldModule = Join-Path $baseline 'src\GpuVM\GpuVM.psd1'

# One password for every lab VM, passed to the child processes encrypted for this user (DPAPI).
$password = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(18)) + 'a1!'
$secure = ConvertTo-SecureString $password -AsPlainText -Force
$credential = [pscredential]::new('gpuvm', $secure)
$encrypted = $secure | ConvertFrom-SecureString

$probeOut = Join-Path $out 'probe.jsonl'
$stop = Join-Path $out 'probe.stop'
$probe = Start-Process pwsh -ArgumentList '-NoProfile', '-File', (Join-Path $repo 'tools\host-probe\probe.ps1'), '-Out', $probeOut, '-StopFile', $stop -WindowStyle Hidden -PassThru
$results = [System.Collections.Generic.List[object]]::new()
$created = [System.Collections.Generic.List[string]]::new()
$keep = $null
try {
    Start-Sleep -Seconds 5
    if ($probe.HasExited) { throw 'La sonda del equipo no arrancó.' }
    Say "Referencia sin carga ($IdleSec s)"
    $t = Get-Date; Start-Sleep -Seconds $IdleSec; Mark 'idle' $t

    $i = 0
    foreach ($variant in $Variants) {
        $i++
        $name = "lab027-$i"
        $module = if ($variant -eq 'old') { $oldModule } else { $newModule }
        if ($variant -eq 'new-cold') {
            $key = & $m { param($iso, $ed) $x = Mount-WindowsIso -IsoPath $iso
                try { $img = Select-WindowsEdition -Editions (Get-WindowsEditionList -ImageFile $x.ImageFile) -Edition $ed; Get-WindowsImageKey -ImageFile $x.ImageFile -ImageIndex $img.Index }
                finally { if (-not $x.WasAttached) { Dismount-DiskImage -ImagePath $x.IsoPath | Out-Null } } } $IsoPath (& $m { param($p) Resolve-GpuVMProfile -Name $p } $Profile)['guest']['edition']
            if ($FreshBase -and (& $m { param($k) Read-WindowsBase -Key $k } $key)) { Say 'Borrando la base de una corrida anterior'; Remove-GpuVMBase -Key $key -Confirm:$false }
            if (& $m { param($k) Read-WindowsBase -Key $k } $key) { Say 'new-cold omitido: la base ya existe'; $results.Add([ordered]@{ variant = $variant; skipped = 'base already there' }); continue }
        }
        Say "$variant → $name"
        $steps = Join-Path $out "$name.steps.log"
        $child = @"
`$ErrorActionPreference = 'Stop'
Import-Module '$module' -Force
`$global:GpuVMProgressSink = { param(`$msg) Add-Content -LiteralPath '$steps' -Value "`$((Get-Date).ToString('o')) `$msg" }
`$cred = [pscredential]::new('gpuvm', (ConvertTo-SecureString '$encrypted'))
New-GpuVM -Name '$name' -IsoPath '$IsoPath' -Profile '$Profile' -Override @{ vm = @{ memoryGB = $MemoryGB } } -Credential `$cred -Confirm:`$false | Out-Null
"@
        $t = Get-Date
        # As a file: on a command line the quotes inside the script are lost.
        $childFile = Join-Path $out "$name.child.ps1"
        Set-Content -LiteralPath $childFile -Value $child -Encoding utf8BOM
        $proc = Start-Process pwsh -ArgumentList '-NoProfile', '-File', $childFile -WindowStyle Minimized -PassThru -Wait -RedirectStandardError (Join-Path $out "$name.err.log")
        $seconds = [math]::Round(((Get-Date) - $t).TotalSeconds, 1)
        if (Get-VM -Name $name -ErrorAction SilentlyContinue) { $created.Add($name) }
        Mark $variant $t @{ vm = $name }
        $ok = $proc.ExitCode -eq 0 -and (Get-VM -Name $name -ErrorAction SilentlyContinue)
        $vhd = if ($ok) { Get-VHD -Path (Get-VMHardDiskDrive -VMName $name | Select-Object -First 1).Path }
        $results.Add([ordered]@{ variant = $variant; vm = $name; seconds = $seconds; ok = [bool]$ok
            fileGB = if ($vhd) { [math]::Round($vhd.FileSize / 1GB, 1) } else { $null }; sizeGB = if ($vhd) { [math]::Round($vhd.Size / 1GB) } else { $null } })
        Say "  $(if ($ok) { 'listo' } else { 'FALLÓ (ver err.log)' }) en $seconds s"
        if (-not $ok) { break }

        Say "  enfriando ($CooldownSec s)"
        $t = Get-Date; Start-Sleep -Seconds $CooldownSec; Mark "$variant-cooldown" $t
        if ($i -lt $Variants.Count) { Remove-GpuVM -Name $name -DeleteDisk -Confirm:$false; $created.Remove($name) | Out-Null }
        else { $keep = $name }
    }

    # ---- The copy must really boot: Windows finishes its setup and C: fills the profile's size.
    if ($keep -and -not $SkipBoot) {
        $needGB = $MemoryGB
        $freeMemGB = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
        if ($freeMemGB -lt $needGB + 0.5) { Say "Arranque omitido: la VM necesita $needGB GB y hay $([math]::Round($freeMemGB, 1)) libres" }
        else {
            Say "Arrancando $keep hasta que Windows esté listo"
            $t = Get-Date
            Start-VM -Name $keep
            & $m { param($n, $c) Wait-GuestReady -Name $n -Credential $c -TimeoutSec 1500 } $keep $credential
            $ready = [math]::Round(((Get-Date) - $t).TotalSeconds)
            $inside = Invoke-Command -VMName $keep -Credential $credential -ScriptBlock {
                [ordered]@{ cGB = [math]::Round((Get-Partition -DriveLetter C).Size / 1GB); caption = (Get-CimInstance Win32_OperatingSystem).Caption; computer = $env:COMPUTERNAME }
            }
            Mark 'first-boot' $t
            $results.Add([ordered]@{ variant = 'first-boot'; vm = $keep; seconds = $ready; cGB = $inside.cGB; caption = $inside.caption; computer = $inside.computer })
            Say "  listo en $ready s; C: $($inside.cGB) GB; $($inside.caption)"
            if ($DiskLab) {
                & (Join-Path $repo 'labs\028-fixed-vs-dynamic\run.ps1') -VMName $keep -Credential $credential -Out $out
            }
        }
    }
}
finally {
    New-Item -ItemType File -Force $stop | Out-Null
    $probe.WaitForExit(10000) | Out-Null
    foreach ($name in $created) {
        try { if ((Get-VM -Name $name).State -ne 'Off') { Stop-VM -Name $name -TurnOff -Force }; Remove-GpuVM -Name $name -DeleteDisk -Confirm:$false }
        catch { Write-Warning "No se pudo borrar ${name}: $($_.Exception.Message)" }
    }
    Remove-Item -Recurse -Force $baseline -ErrorAction SilentlyContinue

    # ---- Summary: each probe sample goes to the phase it fell in.
    $samples = @(if (Test-Path $probeOut) { Get-Content $probeOut | ForEach-Object { $_ | ConvertFrom-Json } })
    function Pct($values, $p) { if (-not $values) { return $null }; $s = @($values | Sort-Object); $s[[math]::Min($s.Count - 1, [math]::Floor($s.Count * $p))] }
    $summary = foreach ($ph in $phases) {
        $a = [datetime]$ph.start; $b = [datetime]$ph.end
        $in = @($samples | Where-Object { $x = [datetime]$_.t; $x -ge $a -and $x -lt $b })
        [ordered]@{
            phase = $ph.phase; seconds = [math]::Round(($b - $a).TotalSeconds); n = $in.Count
            workP50 = Pct $in.work 0.5; workP95 = Pct $in.work 0.95; workP99 = Pct $in.work 0.99
            writeP50 = Pct $in.write 0.5; writeP95 = Pct $in.write 0.95; writeP99 = Pct $in.write 0.99
            readP50 = Pct $in.read 0.5; readP95 = Pct $in.read 0.95; readP99 = Pct $in.read 0.99
            # Hitches a person notices: CPU work 5x slower, a save over 50 ms, an open over 20 ms.
            workSlow = @($in | Where-Object work -gt 10).Count; writeSlow = @($in | Where-Object write -gt 50).Count; readSlow = @($in | Where-Object read -gt 20).Count
            minFreeMB = ($in.freeMB | Measure-Object -Minimum).Minimum
        }
    }
    [ordered]@{ iso = $IsoPath; profile = $Profile; results = $results; phases = $summary } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out 'summary.json')
    $results | ForEach-Object { [pscustomobject]$_ } | Format-Table -AutoSize | Out-String | Write-Host
    $summary | ForEach-Object { [pscustomobject]$_ } | Format-Table phase, seconds, n, workP50, workP95, workP99, writeP95, writeP99, readP95, readP99, workSlow, writeSlow, readSlow, minFreeMB -AutoSize | Out-String -Width 250 | Write-Host
    Say "Resultados en $out"
    Stop-Transcript | Out-Null
}
