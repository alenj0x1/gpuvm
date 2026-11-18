<#
.SYNOPSIS
Lab 043 (security): the two holes the security review asked to close, proved end to end.
  1. module  A folder dropped from this PC that holds a file only administrators can read: Send-GpuVMFile (run from
             an elevated shell, like the bridge) must refuse it and leave nothing in the VM. The same folder without
             that file must still arrive (the fix must not break the normal case).
  2. app     A Low-integrity, restricted process in a job (the viewer's sandbox, as if the stream had taken the viewer
             over) drags host files onto the viewer: the app's drop area appears (the viewer reports "drag"), but its
             drop must refuse a source below Medium, and no copy may start. A Medium source (Explorer's token) is the
             baseline and must be accepted.
The junction swap after the listing is proved in tests/GpuVM.Tests.ps1 ("refuses a folder swapped for a junction").
Needs: win-gpu running, the app installed and showing win-gpu's picture (case 2), the lab lock (taken here).
Writes only under C:\GpuVM-lab-043sec on the host and Desktop\GpuVM-lab-sec in the guest; both are deleted.
#>
param([string]$VMName = 'win-gpu', [int]$X = 960, [int]$Y = 540, [string]$Owner = 'files-clipboard', [int]$Rounds = 3, [switch]$SkipApp)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lock.ps1')
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'; New-Item -ItemType Directory -Force $out | Out-Null
$results = Join-Path $out "security-$(Get-Date -Format yyyyMMdd-HHmmss).jsonl"
$work = 'C:\GpuVM-lab-043sec'
$guestFolder = 'GpuVM-lab-sec'
function Write-Row($row) { $row | ConvertTo-Json -Compress | Add-Content $results; $row | ConvertTo-Json -Compress | Write-Host }

Enter-LabLock -Owner $Owner -Doing 'lab 043: seguridad (archivo solo admin y soltar desde un proceso Low)'
try {
    Import-Module (Join-Path $repo 'src\GpuVM\GpuVM.psd1') -Force
    $m = Get-Module GpuVM
    $cred = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $VMName
    $guestCount = {
        Invoke-Command -VMName $VMName -Credential $cred -ArgumentList $guestFolder {
            param($f) $d = Join-Path ([Environment]::GetFolderPath('Desktop')) $f
            if (Test-Path $d) { @(Get-ChildItem $d -Recurse -Force -ErrorAction SilentlyContinue).Count } else { 0 }
        }
    }
    $guestClear = { Invoke-Command -VMName $VMName -Credential $cred -ArgumentList $guestFolder { param($f) $d = Join-Path ([Environment]::GetFolderPath('Desktop')) $f; if (Test-Path $d) { Get-Item $d | Remove-Item -Recurse -Force } } }

    # ---- 1. module: admin-only file inside a dropped folder
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    $folder = Join-Path $work 'Proyecto'
    New-Item -ItemType Directory -Force $folder | Out-Null
    'mio' | Set-Content (Join-Path $folder 'nota.txt')
    $secret = Join-Path $folder 'gpuvm.json'
    'contraseña de la VM (prueba)' | Set-Content $secret
    $acl = Get-Acl $secret
    $acl.SetAccessRuleProtection($true, $false)
    @($acl.Access) | ForEach-Object { $null = $acl.RemoveAccessRule($_) }
    foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') { $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid, 'FullControl', 'Allow')) }
    Set-Acl $secret $acl
    foreach ($round in 1..$Rounds) {
        & $guestClear
        $err = $null
        try { $null = Send-GpuVMFile -Name $VMName -Path $folder -Folder $guestFolder 6>$null } catch { $err = "$_" }
        Write-Row ([ordered]@{ case = 'admin-only file in folder'; round = $round; elevatedCanRead = [bool](Get-Content $secret -ErrorAction SilentlyContinue)
            refused = [bool]$err; error = $err; itemsInGuest = (& $guestCount) })
    }
    Remove-Item $secret -Force
    foreach ($round in 1..$Rounds) {
        & $guestClear
        $err = $null
        try { $null = Send-GpuVMFile -Name $VMName -Path $folder -Folder $guestFolder 6>$null } catch { $err = "$_" }
        Write-Row ([ordered]@{ case = 'same folder, plain files'; round = $round; refused = [bool]$err; error = $err; itemsInGuest = (& $guestCount) })
    }
    & $guestClear

    # ---- 2. app: a Low, restricted, jobbed source drops host files on the viewer's picture
    if (-not $SkipApp) {
        $exe = Join-Path $work 'DropProbe.exe'
        $csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
        & $csc /nologo /target:winexe /out:$exe /r:System.Windows.Forms.dll /r:System.Drawing.dll (Join-Path $PSScriptRoot 'drop\DropProbe.cs')
        if ($LASTEXITCODE) { throw 'csc' }
        $payload = Join-Path $work 'fotos-del-pc'
        New-Item -ItemType Directory -Force $payload | Out-Null
        1..3 | ForEach-Object { Set-Content (Join-Path $payload "f$_.txt") "archivo $_ del PC" }
        $order = @('Low', 'Medium') * $Rounds
        $i = 0
        foreach ($il in $order) {
            $i++
            & $guestClear
            Start-Sleep -Seconds 4
            # Low writes only under LocalLow, where both sides log.
            $dir = Join-Path $env:USERPROFILE "AppData\LocalLow\GpuVM-lab-043sec\$il-$i"
            New-Item -ItemType Directory -Force $dir | Out-Null
            # The folder (made by this elevated shell) must be writable by a Low process: give it the Low label.
            icacls $dir /setintegritylevel '(OI)(CI)low' | Out-Null
            Start-Process $exe -ArgumentList "launch $il `"$exe`" drop-on `"$dir`" $X $Y `"$payload`""
            Start-Sleep -Seconds 4
            $log = Get-Content (Join-Path $dir 'drop-on.log') -ErrorAction SilentlyContinue
            # A copy, if one started, needs a moment to reach the VM.
            Start-Sleep -Seconds 6
            $done = ($log | Select-String ' done ' | Select-Object -First 1).Line
            Write-Row ([ordered]@{ case = 'drop on the picture'; source = $il; round = $i; integrity = (($log | Select-String 'il=(\S+)').Matches | Select-Object -First 1).Groups[1].Value
                probe = $done; dropAccepted = [bool]($done -match 'effect=Copy'); itemsInGuest = (& $guestCount) })
        }
        & $guestClear
    }
}
finally {
    Get-CimInstance Win32_Process -Filter "Name='DropProbe.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:USERPROFILE 'AppData\LocalLow\GpuVM-lab-043sec') -Recurse -Force -ErrorAction SilentlyContinue
    Exit-LabLock -Owner $Owner
    "resultados: $results"
}
