# Lab 052: does the virtual display boot in StreamMode once Install-GpuVMAgent put it first in vdd_settings.xml?
# One copy of agent-tpl, GpuVM as installed: start it, install the agent (as an open does), wait for the cold boot and
# the agent's sign-in, then read the settings file, the helper's "displays arranged" line and Windows' saved display
# configuration. The copy is deleted at the end. Under the shared lab lock. Run elevated.
param([string]$Template = 'agent-tpl', [string]$Name = 'agent052v', [string]$Session = 'agent-broker', [switch]$ClearSaved)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'
function Line($what) { Write-Host "$(Get-Date -Format HH:mm:ss.fff) $what" }
& (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What "lab 052: VDD boot mode on a copy of $Template" -Me $Session -MaxMinutes 60
if ($LASTEXITCODE) { throw 'no lock' }
$result = [ordered]@{}
try {
    Import-Module (Join-Path $env:ProgramFiles 'GpuVM\gpuvm\src\GpuVM\GpuVM.psd1') -Force
    $m = Get-Module GpuVM
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false }
    New-GpuVM -Name $Name -Template $Template | Out-Null
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes 3GB
    Start-VM -Name $Name
    $state = & $m { param($n) Get-GpuVMState -Name $n } $Name
    $cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
    $result['hasStreaming'] = [bool]$state['streaming']
    $result['virtualDisplay'] = $state['config']['streaming']['virtualDisplay']
    $result['streamMode'] = & $m { param($s) Get-GpuVMStreamMode -State $s } $state
    & $m { param($n, $c) Wait-GuestReady -Name $n -Credential $c } $Name $cred
    $read = {
        $x = 'C:\VirtualDisplayDriver\vdd_settings.xml'
        $first = if (Test-Path $x) { ([xml](Get-Content -Raw $x)).SelectSingleNode('//resolutions/resolution') } else { $null }
        $cfg = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration' -ErrorAction SilentlyContinue | ForEach-Object {
            $k = $_.PSPath
            $sub = Get-ItemProperty "$k\00\00" -ErrorAction SilentlyContinue
            "$($_.PSChildName): $($sub.'PrimSurfSize.cx')x$($sub.'PrimSurfSize.cy')"
        })
        $log = 'C:\ProgramData\GpuVM\Agent\logs\agent.log'
        [ordered]@{
            first = if ($first) { "$($first.width)x$($first.height)@$($first.refresh_rate)" } else { $null }
            saved = $cfg
            arranged = if (Test-Path $log) { @(Select-String -Path $log -Pattern 'displays arranged' | ForEach-Object Line) } else { @() }
            boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')
        }
    }
    $result['before'] = Invoke-Command -VMName $Name -Credential $cred $read
    Line "before install: $($result['before'] | ConvertTo-Json -Compress)"
    $result['install'] = Install-GpuVMAgent -Name $Name
    Line "install: $($result['install'] | ConvertTo-Json -Compress -Depth 4)"
    $result['afterInstall'] = Invoke-Command -VMName $Name -Credential $cred { $x = 'C:\VirtualDisplayDriver\vdd_settings.xml'; $f = ([xml](Get-Content -Raw $x)).SelectSingleNode('//resolutions/resolution'); "$($f.width)x$($f.height)@$($f.refresh_rate)" } -ErrorAction SilentlyContinue
    # The agent's sign-in after the cold boot.
    $deadline = (Get-Date).AddMinutes(6)
    do {
        Start-Sleep -Seconds 10
        $now = try { Invoke-Command -VMName $Name -Credential $cred $read -ErrorAction Stop } catch { $null }
    } while ((Get-Date) -lt $deadline -and -not ($now -and $now.boot -ne $result['before'].boot -and @($now.arranged).Count -gt @($result['before'].arranged).Count))
    $result['after'] = $now
    Line "after boot: $($now | ConvertTo-Json -Compress)"
    if ($ClearSaved) {
        # Windows' saved layouts that include the virtual display (MTT...) go, so the next boot takes the driver's mode.
        $result['cleared'] = @(Invoke-Command -VMName $Name -Credential $cred {
            foreach ($base in 'Configuration', 'Connectivity', 'ScaleFactors') {
                Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\$base" -ErrorAction SilentlyContinue |
                    Where-Object PSChildName -match 'MTT' | ForEach-Object { Remove-Item $_.PSPath -Recurse -Force; "$base\$($_.PSChildName)" }
            }
        })
        Line "cleared: $($result['cleared'].Count) keys"
        $prev = $now
        & $m { param($n) Restart-GpuVMCold -Name $n } $Name
        $deadline = (Get-Date).AddMinutes(6)
        do {
            Start-Sleep -Seconds 10
            $now = try { Invoke-Command -VMName $Name -Credential $cred $read -ErrorAction Stop } catch { $null }
        } while ((Get-Date) -lt $deadline -and -not ($now -and $now.boot -ne $prev.boot -and @($now.arranged).Count -gt @($prev.arranged).Count))
        $result['afterClear'] = $now
        Line "after clear and cold boot: $($now | ConvertTo-Json -Compress)"
    }
}
finally {
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out "vdd-boot-$(Get-Date -Format yyyyMMddHHmmss).json")
    try { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false; Line 'copy deleted' } catch { Line "couldn't delete: $($_.Exception.Message)" }
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Line 'lock released'
}
