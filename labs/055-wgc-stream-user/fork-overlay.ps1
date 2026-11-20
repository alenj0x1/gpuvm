# Lab 055: puts GpuVM's Sunshine fork (gpuvm-sunshine build: sunshine.exe + tools\sunshine_wgc_capture.exe) over
# the official Sunshine in a copy, sets capture = wgc and restarts the service (SYSTEM). -Undo puts the official
# sunshine.exe back (kept as sunshine.exe.official) and removes the capture line. Run elevated.
param([string]$Name = 'agent056', [string]$Build = 'C:\Users\you\Desktop\gpuvm-sunshine\build', [switch]$Undo)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
$m = Get-Module GpuVM
$state = & $m { param($n) Get-GpuVMState -Name $n } $Name
$cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
$s = New-PSSession -VMName $Name -Credential $cred
try {
    Invoke-Command -Session $s { Stop-Service SunshineService -Force; Get-Process sunshine, sunshine_wgc_capture -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 1 }
    if (-not $Undo) {
        Invoke-Command -Session $s {
            $dir = 'C:\Program Files\Sunshine'
            if (-not (Test-Path "$dir\sunshine.exe.official")) { Copy-Item "$dir\sunshine.exe" "$dir\sunshine.exe.official" }
            New-Item -ItemType Directory "$dir\tools" -Force | Out-Null
        }
        Copy-Item (Join-Path $Build 'sunshine.exe') 'C:\Program Files\Sunshine\' -ToSession $s -Force
        Copy-Item (Join-Path $Build 'tools\sunshine_wgc_capture.exe') 'C:\Program Files\Sunshine\tools\' -ToSession $s -Force
    }
    Invoke-Command -Session $s -ArgumentList ([bool]$Undo) {
        param($undo)
        $dir = 'C:\Program Files\Sunshine'
        if ($undo -and (Test-Path "$dir\sunshine.exe.official")) { Copy-Item "$dir\sunshine.exe.official" "$dir\sunshine.exe" -Force }
        $conf = "$dir\config\sunshine.conf"
        $lines = @(Get-Content $conf | Where-Object { $_ -notmatch '^\s*capture\s*=' })
        if (-not $undo) { $lines += 'capture = wgc' }
        Set-Content $conf $lines -Encoding ASCII
        Start-Service SunshineService; Start-Sleep 8
        "sunshine.exe $((Get-Item "$dir\sunshine.exe").Length) bytes; capture: $((Select-String $conf -Pattern '^\s*capture\s*=').Line)"
        Get-CimInstance Win32_Process -Filter "Name='sunshine.exe'" | ForEach-Object { $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner; "sunshine.exe pid $($_.ProcessId) s$($_.SessionId) $($o.Domain)\$($o.User)" }
    }
}
finally { Remove-PSSession $s }
