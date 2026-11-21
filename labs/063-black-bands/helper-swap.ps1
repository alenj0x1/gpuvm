# Lab 063: puts a WGC helper build in a running machine without dropping its viewer (the running helper is ended and
# Sunshine starts the new file in ~1 s), with lab 063's verification on or off; -Restore puts back the helper the
# machine had before the first swap (kept as sunshine_wgc_capture.exe.orig063). Run elevated.
param(
    [Parameter(Mandatory)][string]$Name,
    [string]$Helper,
    [switch]$Verify,
    [switch]$Restore,
    # the fix's own switch: gpuvm-frame-check-off.txt makes the helper skip the unfinished-frame check (A/B, same build)
    [switch]$CheckOff
)
. (Join-Path $PSScriptRoot 'common.ps1')
$cred = Get-Lab063Cred $Name
$s = New-PSSession -VMName $Name -Credential $cred
try {
    if ($Helper) { Copy-Item -ToSession $s -Path $Helper -Destination 'C:\Windows\Temp\wgc-lab063.exe' -Force }
    # In argument mode an unparenthesized [bool]$x is the string "[bool]False" (true): pass a real array.
    Invoke-Command -Session $s -ArgumentList @([bool]$Helper, $Verify.IsPresent, $Restore.IsPresent, $CheckOff.IsPresent) {
        param($new, $verify, $restore, $checkOff)
        $dir = 'C:\Program Files\Sunshine\tools'
        $dst = "$dir\sunshine_wgc_capture.exe"
        if (-not (Test-Path "$dst.orig063")) { Copy-Item $dst "$dst.orig063" }
        if ($verify) { Set-Content "$dir\gpuvm-lab063.txt" 'on' } else { Remove-Item "$dir\gpuvm-lab063.txt" -ErrorAction SilentlyContinue }
        if ($checkOff) { Set-Content "$dir\gpuvm-frame-check-off.txt" 'off' } else { Remove-Item "$dir\gpuvm-frame-check-off.txt" -ErrorAction SilentlyContinue }
        if ($restore) { Remove-Item "$dir\gpuvm-lab063.txt", "$dir\gpuvm-frame-check-off.txt" -ErrorAction SilentlyContinue }
        $src = if ($restore) { "$dst.orig063" } elseif ($new) { 'C:\Windows\Temp\wgc-lab063.exe' } else { $null }
        if ($src) {
            Remove-Item "$dst.old" -Force -ErrorAction SilentlyContinue
            Rename-Item $dst "$dst.old"
            Copy-Item $src $dst
        }
        Get-Process sunshine_wgc_capture -ErrorAction SilentlyContinue | Stop-Process -Force
        if ($restore) { Remove-Item "$dst.orig063" -Force }
    }
    Start-Sleep 6
    Invoke-Command -Session $s {
        $user = (Get-CimInstance Win32_ComputerSystem).UserName.Split('\')[-1]
        $f = Get-ChildItem "C:\Users\$user\AppData\Roaming\Sunshine\wgc-helper" -Filter *.log | Sort-Object Name | Select-Object -Last 1
        "helper $((Get-FileHash 'C:\Program Files\Sunshine\tools\sunshine_wgc_capture.exe').Hash.Substring(0, 12)) log $($f.Name)"
        Get-Content $f.FullName | Where-Object { $_ -match 'lab063|Frame pool created|unfinished-frame check' } | Select-Object -First 5
    }
}
finally { Remove-PSSession $s }
