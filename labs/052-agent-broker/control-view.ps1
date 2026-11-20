# Lab 052, control with GpuVM's own viewer: does Sunshine's capture start over in a loop on a machine WITHOUT the
# agent? A copy of agent-tpl taken back to use=none (its agent uninstalled, the template's administrator signs in),
# then -Rounds rounds of wgc and ddx (Set-GpuVMCapture), -Opens opens each, every open made the way a person makes it:
# the machine's Open button in GpuVM's window, pressed through UI Automation (no mouse, no keyboard; `gpuvm.exe --view`
# only opens machines an agent session holds). Per open: when the viewer shows, when it shows a picture (the spread
# of its brightness over 60, never a mean: GpuVM's empty panel once passed for one), screenshots at both ends, and
# Sunshine's capture restarts in its log. This branch's module (read-only, the installed agent package and viewer);
# the copy is deleted at the end. Under the shared lab lock. Run elevated.
param([string]$Template = 'agent-tpl', [string]$Name = 'agent052v2', [string]$Session = 'agent-broker', [int]$Opens = 4,
    [int]$Rounds = 2, [int]$PictureLimitSec = 20, [int]$WindowLimitSec = 240)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$module = Join-Path $root 'src\GpuVM\GpuVM.psd1'
$installed = Join-Path $env:ProgramFiles 'GpuVM\gpuvm'
$lumaShot = Join-Path $PSScriptRoot 'luma-shot.ps1'
function Line($what) { Write-Host "$(Get-Date -Format HH:mm:ss.fff) $what" }
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$UIA = [System.Windows.Automation.AutomationElement]
# GpuVM's window as UI Automation sees it: every element, in order.
function Get-AppElements {
    $p = Get-Process gpuvm -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
    if (-not $p) { return @() }
    @($UIA::FromHandle($p.MainWindowHandle).FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition))
}
$script:buttonsLogged = $false
# The machine's Open button: its page from the sidebar (the button named after it), then that page's open button.
# The page's buttons are logged once (first run: the home card's first button after the name wasn't it).
function Find-OpenButton {
    $isButton = { param($e) $e.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button }
    $side = @(Get-AppElements | Where-Object { (& $isButton $_) -and $_.Current.Name -eq $Name }) | Select-Object -First 1
    if (-not $side) { return $null }
    $side.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Seconds 2
    $buttons = @(Get-AppElements | Where-Object { & $isButton $_ })
    if (-not $script:buttonsLogged) { Line "machine page buttons: $(@($buttons | ForEach-Object { "'$($_.Current.Name)'" }) -join ' ')"; $script:buttonsLogged = $true }
    @($buttons | Where-Object { $_.Current.Name -match '^(Open|Abrir|Connect|Conectar)\b' }) | Select-Object -First 1
}
function Read-Luma([string]$Save) {
    $r = if ($Save) { & $lumaShot -Save (Join-Path $out $Save) } else { & $lumaShot }
    if ("$r" -eq 'none') { return $null }
    $parts = "$r".Split(' '); [pscustomobject]@{ Mean = [double]$parts[0]; Spread = [double]$parts[1] }
}
& (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What "lab 052: capture control with GpuVM's viewer, no agent" -Me $Session -MaxMinutes 180
if ($LASTEXITCODE) { throw 'no lock' }
$made = $false
$result = [ordered]@{ module = "$(git -C $root rev-parse --short HEAD)"; opens = @() }
try {
    Import-Module $module -Force
    $m = Get-Module GpuVM
    & $m {
        param($viewer, $dist)
        $script:LabViewer = $viewer; $script:LabDist = $dist
        function script:Get-GpuVMViewerPath { $script:LabViewer }
        function script:Get-RepoPath { param($Relative) if ($Relative -eq 'guest\agent') { $script:LabDist } else { Join-Path $script:RepoRoot $Relative } }
    } (Join-Path $installed 'viewer\GpuVMViewer.exe') (Join-Path $installed 'guest\agent')
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false }
    New-GpuVM -Name $Name -Template $Template | Out-Null
    $made = $true
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes 3GB
    Start-VM -Name $Name
    $state = & $m { param($n) Get-GpuVMState -Name $n } $Name
    $cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
    & $m { param($n, $c) Wait-GuestReady -Name $n -Credential $c } $Name $cred
    $result['use'] = Set-GpuVMUse -Name $Name -Use none
    $result['useAfter'] = [string](& $m { param($n) (Get-GpuVMState -Name $n)['use'] } $Name)
    # The template's administrator signs in automatically on this throwaway copy (lab only; deleted at the end).
    $plain = $cred.GetNetworkCredential()
    Invoke-Command -VMName $Name -Credential $cred -ArgumentList $plain.UserName, $plain.Password {
        param($u, $p)
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty $k AutoAdminLogon '1'; Set-ItemProperty $k DefaultUserName $u; Set-ItemProperty $k DefaultPassword $p
        Set-ItemProperty $k DefaultDomainName $env:COMPUTERNAME
    }
    $plain = $null
    & $m { param($n) Restart-GpuVMCold -Name $n } $Name
    & $m { param($n, $c) Wait-GuestReady -Name $n -Credential $c } $Name $cred
    $result['console'] = Invoke-Command -VMName $Name -Credential $cred { "$((Get-CimInstance Win32_ComputerSystem).UserName)" }
    Line "use: '$($result['useAfter'])', signed in: $($result['console'])"
    $logFile = 'C:\Program Files\Sunshine\config\sunshine.log'
    for ($round = 1; $round -le $Rounds; $round++) {
        foreach ($capture in 'wgc', 'ddx') {
            Line "=== round $round, capture $capture"
            Set-GpuVMCapture -Name $Name -Mode $capture | Out-Null
            for ($i = 1; $i -le $Opens; $i++) {
                Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Stop-Process -Force
                Start-Sleep -Seconds 3
                $button = $null
                for ($t = 0; $t -lt 30 -and -not $button; $t++) { $button = Find-OpenButton; if (-not $button) { Start-Sleep -Seconds 2 } }
                if (-not $button) {
                    $names = @(Get-AppElements | ForEach-Object { "$($_.Current.ControlType.ProgrammaticName -replace 'ControlType.') '$($_.Current.Name)'" } | Where-Object { $_ -notmatch "Image ''|Group ''|Pane ''" })
                    throw "no Open button for $Name in GpuVM's window: $($names -join ' | ')"
                }
                $logBefore = Invoke-Command -VMName $Name -Credential $cred -ArgumentList $logFile { param($f) @(Get-Content $f).Count }
                $started = Get-Date
                $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                $tag = "c$round$capture$i"
                $open = [ordered]@{ round = $round; capture = $capture; n = $i; windowSec = $null; pictureSec = $null; firstSpread = $null; lastSpread = $null }
                $limit = $WindowLimitSec
                while (((Get-Date) - $started).TotalSeconds -lt $limit -and $null -eq $open['pictureSec']) {
                    $l = Read-Luma $(if ($null -eq $open['windowSec']) { "control-view-$stamp-$tag-first.png" } else { $null })
                    if ($l) {
                        $sec = [math]::Round(((Get-Date) - $started).TotalSeconds, 2)
                        if ($null -eq $open['windowSec']) { $open['windowSec'] = $sec; $open['firstSpread'] = $l.Spread; $limit = $sec + $PictureLimitSec }
                        if ($l.Spread -gt 60) { $open['pictureSec'] = $sec }
                    }
                    Start-Sleep -Milliseconds 250
                }
                $end = Read-Luma "control-view-$stamp-$tag-end.png"
                $open['lastSpread'] = if ($end) { $end.Spread } else { $null }
                Start-Sleep -Seconds 2
                $log = @(Invoke-Command -VMName $Name -Credential $cred -ArgumentList $logFile, $logBefore { param($f, $from) Get-Content $f | Select-Object -Skip $from })
                $open['capture'] = $capture
                $open['captureRestarts'] = @($log | Where-Object { $_ -match 'Desktop resolution' }).Count
                $open['encoders'] = @($log | Where-Object { $_ -match 'Creating encoder' }).Count
                $open['sessions'] = @($log | Where-Object { $_ -match 'CLIENT CONNECTED' }).Count
                Line "open $i ($capture): window $($open['windowSec']) s, picture $($open['pictureSec']) s, spread $($open['firstSpread'])->$($open['lastSpread']), sessions $($open['sessions']), capture restarts $($open['captureRestarts']), encoders $($open['encoders'])"
                $result['opens'] += $open
            }
        }
    }
}
catch { $result['error'] = "$($_.Exception.Message)"; Line "ERROR $($result['error'])" }
finally {
    Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Stop-Process -Force
    if ($made) {
        try { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false; Line "$Name deleted" }
        catch { Line "couldn't delete $Name : $($_.Exception.Message)" }
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out "control-view-$stamp.json") -Encoding utf8
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Line 'lock released'
}
