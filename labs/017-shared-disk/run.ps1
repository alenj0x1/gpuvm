# Lab 017: a shared disk on a real VM. Creates a small test disk, attaches it to the running VM (hot-add), checks the
# drive letter and Steam library inside, detaches it (hot-remove), imports a host folder shaped like a Steam library,
# attaches it again and checks the game manifest arrived. Removes the test disk at the end. Run elevated:
#   pwsh -File labs/017-shared-disk/run.ps1 -VMName win10
param(
    [string]$VMName = 'win10',
    [string]$Out = (Join-Path $PSScriptRoot 'out\result.txt')
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
Start-Transcript -Path $Out -Force | Out-Null
$name = 'lab017'
$m = Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force -PassThru
$cred = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $VMName
$inside = {
    param($label)
    $v = Get-Volume -FileSystemLabel $label -ErrorAction SilentlyContinue | Select-Object -First 1
    $vdf = Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\libraryfolders.vdf'
    [ordered]@{
        letter     = if ($v) { [string]$v.DriveLetter } else { '' }
        library    = if ($v -and $v.DriveLetter) { Test-Path "$($v.DriveLetter):\SteamLibrary" } else { $false }
        manifest   = if ($v -and $v.DriveLetter) { Test-Path "$($v.DriveLetter):\SteamLibrary\steamapps\appmanifest_480.acf" } else { $false }
        steamEntry = if (Test-Path $vdf) { (Get-Content -Raw $vdf).Contains("SteamLibrary") } else { $false }
        steamOpen  = [bool](Get-Process steam -ErrorAction SilentlyContinue)
    }
}
try {
    "== VM ${VMName}: $((Get-VM $VMName).State)"
    $t = [Diagnostics.Stopwatch]::StartNew()
    New-GpuVMSharedDisk -Name $name -SizeGB 64 -Purpose games -Confirm:$false | Out-Null
    "create: $([int]$t.Elapsed.TotalSeconds) s"

    $t.Restart()
    $c = Connect-GpuVMSharedDisk -Name $name -VMName $VMName -WarningVariable w1
    "connect (hot-add): $([int]$t.Elapsed.TotalSeconds) s, letter $($c['letter'])"
    $w1 | ForEach-Object { "WARN $_" }
    "inside: " + ((Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock $inside -ArgumentList $name) | ConvertTo-Json -Compress)

    $t.Restart()
    Disconnect-GpuVMSharedDisk -Name $name | Out-Null
    "disconnect (hot-remove): $([int]$t.Elapsed.TotalSeconds) s"

    # A host folder shaped like a Steam library: steamapps with a manifest and a 200 MB game folder.
    $src = Join-Path ([IO.Path]::GetTempPath()) 'lab017-steam'
    New-Item -ItemType Directory -Force "$src\steamapps\common\Spacewar" | Out-Null
    '"AppState" { "appid" "480" "name" "Spacewar" "installdir" "Spacewar" }' | Set-Content "$src\steamapps\appmanifest_480.acf"
    $bytes = [byte[]]::new(200MB); [Random]::new(1).NextBytes($bytes); [IO.File]::WriteAllBytes("$src\steamapps\common\Spacewar\data.bin", $bytes)
    $t.Restart()
    $i = Import-GpuVMSharedDisk -Name $name -Path $src
    "import 200 MB: $([math]::Round($t.Elapsed.TotalSeconds, 1)) s into $($i['folder'])"

    Connect-GpuVMSharedDisk -Name $name -VMName $VMName | Out-Null
    "inside after import: " + ((Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock $inside -ArgumentList $name) | ConvertTo-Json -Compress)
    Disconnect-GpuVMSharedDisk -Name $name | Out-Null
    "list: " + ((Get-GpuVMSharedDisk | Where-Object { $_['name'] -eq $name }) | ConvertTo-Json -Compress)
}
catch { "ERROR: $($_.Exception.Message)"; $_.ScriptStackTrace }
finally {
    try { Disconnect-GpuVMSharedDisk -Name $name -ErrorAction SilentlyContinue | Out-Null } catch {}
    try { Remove-GpuVMSharedDisk -Name $name -Confirm:$false | Out-Null; 'test disk removed' } catch { "cleanup: $_" }
    # The Steam entry for the test disk is taken out again, from the backup made when it was added.
    # Steam is closed for it (as GpuVM does) and opened again.
    Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
        $vdf = Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\libraryfolders.vdf'
        if (-not (Test-Path "$vdf.gpuvm.bak")) { return }
        $exe = Join-Path ${env:ProgramFiles(x86)} 'Steam\steam.exe'
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        $run = {
            param($a)
            $t = "lab017-$([guid]::NewGuid().ToString('n'))"
            Register-ScheduledTask -TaskName $t -Action (New-ScheduledTaskAction -Execute $exe -Argument $a) -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
            Start-ScheduledTask -TaskName $t; Start-Sleep 2; Unregister-ScheduledTask -TaskName $t -Confirm:$false
        }
        $open = [bool](Get-Process steam -ErrorAction SilentlyContinue)
        if ($open) { & $run '-shutdown'; for ($i = 0; $i -lt 30 -and (Get-Process steam -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 } }
        if (-not (Get-Process steam -ErrorAction SilentlyContinue)) { Move-Item "$vdf.gpuvm.bak" $vdf -Force; 'steam vdf restored' }
        if ($open) { & $run '-silent' }
    }
    Remove-Item -Recurse -Force (Join-Path ([IO.Path]::GetTempPath()) 'lab017-steam') -ErrorAction SilentlyContinue
    Stop-Transcript | Out-Null
}
