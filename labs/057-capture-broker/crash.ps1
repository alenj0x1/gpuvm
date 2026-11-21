# Lab 057: what a crash of Windows' capture broker (CaptureService_<id>, where WGC sessions live) does to the stream of
# a machine with a viewer open. Ends the broker's process like the access violation of 2026-11-21 11:25 did, then
# reads, from the guest's own logs, whether the WGC helper started over and when frames came back.
# -Install puts a helper build in the guest first (the running helper is renamed, not stopped: no viewer drops).
# Run elevated. Out: out\<label>.json
param([Parameter(Mandatory)][string]$Name, [string]$Label = 'crash', [string]$Install, [int]$Seconds = 40)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
$m = Get-Module GpuVM
$state = & $m { param($n) Get-GpuVMState -Name $n } $Name
$cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
$s = New-PSSession -VMName $Name -Credential $cred
try {
    if ($Install) {
        Copy-Item -ToSession $s -Path $Install -Destination 'C:\Windows\Temp\wgc-new.exe'
        Invoke-Command -Session $s {
            $dst = 'C:\Program Files\Sunshine\tools\sunshine_wgc_capture.exe'
            Remove-Item "$dst.old" -Force -ErrorAction SilentlyContinue
            Rename-Item $dst "$dst.old"
            Move-Item 'C:\Windows\Temp\wgc-new.exe' $dst
            # Sunshine starts the new file in ~1 s (broken pipe -> re-init); the viewer stays connected.
            Get-Process sunshine_wgc_capture -ErrorAction SilentlyContinue | Stop-Process -Force
        }
        Start-Sleep 8
    }
    $before = Invoke-Command -Session $s {
        $log = 'C:\Program Files\Sunshine\config\sunshine.log'
        [pscustomobject]@{
            lines  = @(Get-Content $log).Count
            helper = (Get-Process sunshine_wgc_capture -ErrorAction SilentlyContinue | Select-Object -First 1).Id
            hash   = (Get-FileHash 'C:\Program Files\Sunshine\tools\sunshine_wgc_capture.exe').Hash.Substring(0, 12)
            broker = (Get-CimInstance Win32_Service -Filter "Name LIKE 'CaptureService[_]%'" | Where-Object ProcessId).ProcessId
        }
    }
    if (-not $before.broker) { throw 'No capture broker runs (is a viewer open?).' }
    $t0 = Get-Date
    Invoke-Command -Session $s -ArgumentList $before.broker { param($p) Stop-Process -Id $p -Force }
    Start-Sleep $Seconds
    $after = Invoke-Command -Session $s -ArgumentList $before.lines, $t0 {
        param($from, $t0)
        $new = @(Get-Content 'C:\Program Files\Sunshine\config\sunshine.log' | Select-Object -Skip $from)
        $dir = Get-ChildItem 'C:\Users\*\AppData\Roaming\Sunshine' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
        $logs = @(Get-ChildItem $dir.FullName -Recurse -Filter '*.log*' | Where-Object LastWriteTime -gt $t0.AddSeconds(-60) | Sort-Object LastWriteTime)
        $helperLines = @($logs | ForEach-Object { Get-Content $_.FullName -ErrorAction SilentlyContinue } |
            Where-Object { $_ -match 'stall probe|capture broker|capture_fps|Capture item closed|terminated' })
        [pscustomobject]@{
            sunshine = @($new | Where-Object { $_ -match 'WGC helper|IPC pipe|Broken pipe|keyed mutex|CLIENT' })
            helper   = $helperLines | Select-Object -Last 40
            helperId = (Get-Process sunshine_wgc_capture -ErrorAction SilentlyContinue | Select-Object -First 1).Id
            broker   = (Get-CimInstance Win32_Service -Filter "Name LIKE 'CaptureService[_]%'" | Where-Object ProcessId).ProcessId
        }
    }
    $restart = $after.sunshine | Where-Object { $_ -match 'WGC helper: capturing' } | Select-Object -First 1
    $result = [ordered]@{
        label = $Label; at = $t0.ToString('s'); helperHash = $before.hash
        brokerBefore = $before.broker; brokerAfter = $after.broker
        helperBefore = $before.helper; helperAfter = $after.helperId
        helperRestarted = [bool]$restart
        restartAfterS = if ($restart -match '^\[(.+?)\]') { [math]::Round(([datetime]$Matches[1] - $t0).TotalSeconds, 1) } else { $null }
        sunshine = $after.sunshine; helper = $after.helper
    }
    New-Item -ItemType Directory -Force (Join-Path $PSScriptRoot 'out') | Out-Null
    $result | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $PSScriptRoot "out\$Label.json")
    [pscustomobject]$result
}
finally { Remove-PSSession $s }
