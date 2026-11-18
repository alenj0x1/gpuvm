<#
.SYNOPSIS
Lab 043 (VM -> VM): "Enviar lo seleccionado a" between two real machines, with this branch's module.
In the source machine it makes a GpuVM-lab folder (a 64 MB file, a folder of 200 small files, a name with ñ),
selects it in File Explorer (explorer /select in the signed-in session), reads the selection with
Get-GpuVMExplorerSelection and sends it with Send-GpuVMFile -FromVM. Checks size and hash in the target, then deletes
the test files on both sides. Expects both machines running (the caller holds the lab lock).
#>
param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To, [int]$Rounds = 2)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $repo 'src\GpuVM\GpuVM.psd1') -Force
$m = Get-Module GpuVM
$credOf = { param($n) & $m { param($x) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $x) } $n }
$src = & $credOf $From; $dst = & $credOf $To
$out = Join-Path $PSScriptRoot 'out'; New-Item -ItemType Directory -Force $out | Out-Null
$results = Join-Path $out "vm2vm-$(Get-Date -Format yyyyMMdd-HHmmss).jsonl"
try {
    $made = Invoke-Command -VMName $From -Credential $src {
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        $sid = ([Security.Principal.NTAccount]$user).Translate([Security.Principal.SecurityIdentifier]).Value
        $desk = Join-Path (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid").ProfileImagePath 'Desktop'
        $root = Join-Path $desk 'GpuVM-lab'
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force "$root\Lote año\sub" | Out-Null
        $rng = [Random]::new(43)
        $b = [byte[]]::new(64MB); $rng.NextBytes($b); [IO.File]::WriteAllBytes("$root\grande.bin", $b)
        foreach ($i in 1..200) { $s = [byte[]]::new($rng.Next(1KB, 32KB)); $rng.NextBytes($s); [IO.File]::WriteAllBytes("$root\Lote año\sub\f$i.bin", $s) }
        Set-Content "$root\Lote año\canción.txt" 'hola'
        # Select both items in one Explorer window, as a person would (explorer /select takes one; the shell API the rest).
        $script = Join-Path $env:ProgramData 'gpuvm-lab-select.ps1'
        Set-Content $script -Encoding UTF8 @"
Start-Process explorer.exe -ArgumentList '/select,"$root\grande.bin"'
Start-Sleep -Seconds 3
`$w = @((New-Object -ComObject Shell.Application).Windows()) | Where-Object { `$_.Document.Folder.Self.Path -eq '$root' } | Select-Object -First 1
`$w.Document.SelectItem(`$w.Document.Folder.ParseName('Lote año'), 1)
"@
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
        Register-ScheduledTask -TaskName 'GpuVM-lab-select' -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
        Start-ScheduledTask -TaskName 'GpuVM-lab-select'
        Start-Sleep -Seconds 6
        Unregister-ScheduledTask -TaskName 'GpuVM-lab-select' -Confirm:$false
        Remove-Item $script -Force
        @{ root = $root; hash = (Get-FileHash "$root\grande.bin").Hash; files = @(Get-ChildItem $root -Recurse -File).Count; bytes = (Get-ChildItem $root -Recurse -File | Measure-Object Length -Sum).Sum }
    }
    "origen: $($made.files) archivos, $([math]::Round($made.bytes / 1MB, 1)) MB en $($made.root)"
    $sel = Get-GpuVMExplorerSelection -Name $From
    "seleccionado en el Explorador de ${From}: $($sel['names'] -join ', ')"
    if (@($sel['paths']).Count -ne 2) { throw "Se esperaban 2 elementos seleccionados." }
    foreach ($round in 1..$Rounds) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Send-GpuVMFile -Name $To -FromVM $From -Path $sel['paths'] -Folder 'GpuVM-lab-recibidos'
        $ms = $sw.ElapsedMilliseconds
        $got = Invoke-Command -VMName $To -Credential $dst -ArgumentList (, [string[]]$r['items']) {
            param($items)
            $user = (Get-CimInstance Win32_ComputerSystem).UserName
            $sid = ([Security.Principal.NTAccount]$user).Translate([Security.Principal.SecurityIdentifier]).Value
            $dir = Join-Path (Join-Path (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid").ProfileImagePath 'Desktop') 'GpuVM-lab-recibidos'
            $big = $items | Where-Object { $_ -like 'grande*' } | Select-Object -First 1
            @{ files = @(Get-ChildItem $dir -Recurse -File).Count; hash = (Get-FileHash (Join-Path $dir $big)).Hash; items = $items }
        }
        $row = [ordered]@{ round = $round; from = $From; to = $To; ms = $ms; mb = [math]::Round($r['bytes'] / 1MB, 1); mbps = [math]::Round($r['bytes'] / 1MB / ($ms / 1000), 1)
            hashOk = $got['hash'] -eq $made['hash']; items = ($got['items'] -join ', '); filesInTarget = $got['files'] }
        $row | ConvertTo-Json -Compress | Add-Content $results
        "r$round ${From} -> ${To}: $($row.ms) ms, $($row.mbps) MB/s, hash $(if ($row.hashOk) { 'igual' } else { 'DISTINTO' }), $($row.items)"
    }
}
finally {
    Invoke-Command -VMName $From -Credential $src { Get-ChildItem "$env:SystemDrive\Users\*\Desktop\GpuVM-lab" -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force } -ErrorAction SilentlyContinue
    Invoke-Command -VMName $To -Credential $dst { Get-ChildItem "$env:SystemDrive\Users\*\Desktop\GpuVM-lab-recibidos" -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force } -ErrorAction SilentlyContinue
    "resultados: $results"
}
