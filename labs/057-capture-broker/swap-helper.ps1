# Lab 057: puts a WGC helper build (and, optionally, the lab copy delay in microseconds) in a running machine
# without dropping its viewer: the running helper is renamed and ended, and Sunshine starts the new file in ~1 s.
# Prints the new helper's first copy-wait line. Run elevated.
param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Helper, [int]$DelayUs = -1)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
$m = Get-Module GpuVM
$state = & $m { param($n) Get-GpuVMState -Name $n } $Name
$cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
$s = New-PSSession -VMName $Name -Credential $cred
try {
    Copy-Item -ToSession $s -Path $Helper -Destination 'C:\Windows\Temp\wgc-new.exe'
    Invoke-Command -Session $s -ArgumentList $DelayUs {
        param($delay)
        $dir = 'C:\Program Files\Sunshine\tools'
        if ($delay -ge 0) { Set-Content "$dir\gpuvm-lab.txt" $delay } else { Remove-Item "$dir\gpuvm-lab.txt" -ErrorAction SilentlyContinue }
        $dst = "$dir\sunshine_wgc_capture.exe"
        Remove-Item "$dst.old" -Force -ErrorAction SilentlyContinue
        Rename-Item $dst "$dst.old"
        Move-Item 'C:\Windows\Temp\wgc-new.exe' $dst
        Get-Process sunshine_wgc_capture -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    Start-Sleep 18
    Invoke-Command -Session $s {
        # The signed-in user's folder (agent machines: agent); a wildcard path here listed nothing.
        $user = (Get-CimInstance Win32_ComputerSystem).UserName -replace '^.*\\'
        $f = Get-ChildItem "C:\Users\$user\AppData\Roaming\Sunshine\wgc-helper" -Filter *.log | Sort-Object Name | Select-Object -Last 1
        Get-Content $f.FullName | Where-Object { $_ -match 'lab: copy delay|copy wait|capture_fps' } | ForEach-Object { $_.Substring(0, [Math]::Min(170, $_.Length)) }
    }
}
finally { Remove-PSSession $s }
