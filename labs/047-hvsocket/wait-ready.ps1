# Waits (at most -MaxMinutes) until a freshly installed test VM is usable: PowerShell Direct answers, the user is
# signed in (explorer.exe), Sunshine's service runs and the NVIDIA GPU-P adapter is working. Prints one line per change.
param([Parameter(Mandatory)][string]$Name, [int]$MaxMinutes = 30)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
. (Join-Path $PSScriptRoot '..\..\tools\latency\common.ps1')
$cred = (Get-LatencyVM -Name $Name).Guest
$sw = [Diagnostics.Stopwatch]::StartNew()
$last = ''
while ($sw.Elapsed.TotalMinutes -lt $MaxMinutes) {
    if ((Get-VM -Name $Name).State -ne 'Running') { throw "VM $Name is $((Get-VM -Name $Name).State)" }
    $st = try {
        Invoke-Command -VMName $Name -Credential $cred -ErrorAction Stop {
            $gpu = Get-CimInstance Win32_VideoController | Where-Object Name -match 'NVIDIA' | Select-Object -First 1
            $sun = Get-Service -Name SunshineService -ErrorAction SilentlyContinue
            [pscustomobject]@{
                explorer = [bool](Get-Process explorer -ErrorAction SilentlyContinue)
                sunshine = if ($sun) { "$($sun.Status)" } else { 'missing' }
                gpu = if ($gpu) { "$($gpu.Status)" } else { 'missing' }
                user = (Get-CimInstance Win32_ComputerSystem).UserName
            }
        }
    } catch { $null }
    $line = if ($st) { "psdirect ok, user=$($st.user), explorer=$($st.explorer), sunshine=$($st.sunshine), gpu=$($st.gpu)" } else { 'psdirect not yet' }
    if ($line -ne $last) { "{0:N1} min: {1}" -f $sw.Elapsed.TotalMinutes, $line; $last = $line }
    if ($st -and $st.explorer -and $st.sunshine -eq 'Running' -and $st.gpu -eq 'OK') { 'READY'; exit 0 }
    Start-Sleep -Seconds 15
}
'TIMEOUT'; exit 1
