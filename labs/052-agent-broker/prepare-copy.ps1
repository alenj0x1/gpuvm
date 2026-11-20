# Lab 052 helper (viewer-black.mjs, LAB052_VARIANT=mttclear): what 4501f1b adds, applied to a copy GpuVM just made,
# with this branch's module (read-only): the stream mode first in vdd_settings.xml, Windows' saved layouts of the
# virtual display forgotten, and with -SunshineDebug Sunshine's min_log_level = debug in sunshine.conf; then a power
# cycle, so Sunshine and the display start with all of it.
# A copy that just started can drop PowerShell Direct ("the Hyper-V socket target process has ended", 2026-11-20,
# twice): the guest must answer three times in a row first, and each step is retried.
param([Parameter(Mandatory)][string]$Name, [switch]$SunshineDebug)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$m = Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force -PassThru
$state = & $m { param($n) Get-GpuVMState -Name $n } $Name
$cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
$mode = & $m { param($s) Get-GpuVMStreamMode -State $s } $state
function Retry([scriptblock]$Do, [string]$What) {
    for ($i = 1; ; $i++) {
        try { return & $Do }
        catch { if ($i -ge 8) { throw "$What failed $i times: $($_.Exception.Message)" }; Start-Sleep -Seconds 10 }
    }
}
$streak = 0; $deadline = (Get-Date).AddMinutes(5)
while ($streak -lt 3 -and (Get-Date) -lt $deadline) {
    try { $null = Invoke-Command -VMName $Name -Credential $cred -ErrorAction Stop { 1 }; $streak++ } catch { $streak = 0 }
    Start-Sleep -Seconds 5
}
if ($streak -lt 3) { throw "'$Name' didn't answer steadily in 5 min." }
$out = [ordered]@{ mode = $mode }
if ($SunshineDebug) {
    $out['debugConf'] = Retry -What 'writing sunshine.conf' {
        Invoke-Command -VMName $Name -Credential $cred -ErrorAction Stop {
            $f = 'C:\Program Files\Sunshine\config\sunshine.conf'
            $l = @(Get-Content $f | Where-Object { $_ -notmatch '^\s*min_log_level\s*=' })
            Set-Content $f (@($l) + 'min_log_level = debug')
            [bool](Select-String -Path $f -Pattern '^min_log_level = debug$' -Quiet)
        }
    }
}
$null = $mode -match '^(\d+)x(\d+)@(\d+)$'
$w = $Matches[1]; $h = $Matches[2]; $hz = $Matches[3]
$out['vddChanged'] = Retry -What 'the virtual display''s mode' { & $m { param($n, $c, $w, $h, $hz) Set-GuestVddPreferredMode -Name $n -Credential $c -Width $w -Height $h -Hz $hz } $Name $cred $w $h $hz }
& $m { param($n) Restart-GpuVMCold -Name $n } $Name
$out | ConvertTo-Json -Compress
