# Lab 055: runs the WGC probe (probe055.exe, built in the guest from Probe055.cs) as gpuvm-stream with and without
# the session's logon SID, and as the session's own user, and prints each line. Run elevated.
param([string]$Name = 'agent055', [string[]]$Variants = @('sid', 'nosid', 'agent'))
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
$m = Get-Module GpuVM
$state = & $m { param($n) Get-GpuVMState -Name $n } $Name
$cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
$switches = { param($on) foreach ($x in 'probe', 'nosid', 'asagent', 'interactive') { $p = "C:\GpuVMLab055\$x"; if ($x -in $on) { New-Item $p -Force | Out-Null } elseif (Test-Path $p) { Remove-Item -LiteralPath $p } } }
foreach ($v in $Variants) {
    $on = @('probe') + $(if ($v -eq 'nosid') { 'nosid' } elseif ($v -eq 'agent') { 'asagent' } elseif ($v -eq 'interactive') { 'interactive' } elseif ($v -eq 'interactive-nosid') { 'interactive', 'nosid' } else { @() })
    Invoke-Command -VMName $Name -Credential $cred $switches -ArgumentList (, $on)
    & (Join-Path $PSScriptRoot 'swap.ps1') -Name $Name -Mode user *> $null
    Invoke-Command -VMName $Name -Credential $cred -ArgumentList $v {
        param($v)
        $end = (Get-Date).AddSeconds(40)
        while ((Get-Date) -lt $end -and -not ((Get-Content C:\GpuVMLab055\launch.log -Raw) -match 'sunshine: ')) { Start-Sleep -Milliseconds 500 }
        "== $v | $((Get-Content C:\GpuVMLab055\launch.log | Select-Object -Last 1))"
        foreach ($u in 'gpuvm-stream', 'agent') { $f = "C:\GpuVMLab055\out\probe-$u.txt"; if (Test-Path $f) { Get-Content $f | Select-Object -Last 1 } }
    }
}
Invoke-Command -VMName $Name -Credential $cred $switches -ArgumentList (, @())
