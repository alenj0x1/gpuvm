# Lab 022: the VM's virtual display at the host monitor's refresh rate (180 Hz), so each streamed frame lands on one
# host refresh. Adds 180 to the refresh rates of the Virtual Display Driver in the VM (backing up its settings), then
#   - smoothness (lab 021's bar) at 180 FPS with and without V-Sync and with pacing, and at 165 for comparison;
#   - input latency (lab 020's squares) at 180 and 120 FPS, with and without V-Sync;
#   - saves Sunshine's log, to see what happens while the picture stays black after Moonlight reconnects.
# Takes over the screen, mouse and keyboard while it runs. Run elevated, in the signed-in user's session:
#   pwsh -File labs/022-matched-refresh/run.ps1 -Name win10
param(
    [string]$Name = 'win10',
    [int]$Hz = 180,
    [int]$Rounds = 2,
    [switch]$SkipVdd,
    [string]$OutDir = (Join-Path $PSScriptRoot "out\run-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$labs = Split-Path $PSScriptRoot
. (Join-Path $labs '..\tools\latency\common.ps1')
$vm = Get-LatencyVM -Name $Name

if (-not $SkipVdd) {
    $vdd = Invoke-Command -VMName $Name -Credential $vm.Guest -ArgumentList $Hz -ScriptBlock {
        param($hz)
        $path = 'C:\VirtualDisplayDriver\vdd_settings.xml'
        [xml]$xml = Get-Content -LiteralPath $path -Raw
        $rates = @($xml.SelectNodes('//g_refresh_rate'))
        $before = @($rates | ForEach-Object { $_.InnerText })
        $added = $false
        if ($rates.Count -and "$hz" -notin $before) {
            Copy-Item $path "$path.bak-lab022" -Force
            $node = $xml.CreateElement('g_refresh_rate')
            $node.InnerText = "$hz"
            [void]$rates[0].ParentNode.AppendChild($node)
            $xml.Save($path)
            # The driver reads its settings when the device starts.
            $device = Get-PnpDevice -Class Display | Where-Object { $_.HardwareID -contains 'Root\MttVDD' }
            $device | Disable-PnpDevice -Confirm:$false
            Start-Sleep -Seconds 3
            $device | Enable-PnpDevice -Confirm:$false
            Start-Sleep -Seconds 8
            $added = $true
        }
        [pscustomobject]@{ before = $before -join ','; added = $added; parent = if ($rates.Count) { $rates[0].ParentNode.Name } else { $null } }
    }
    "vdd refresh rates before: $($vdd.before) (in <$($vdd.parent)>), added $Hz : $($vdd.added)" | Write-Host
}
$set = & $vm.Module { param($n, $c, $f) Set-GuestDisplayResolution -Name $n -Credential $c -Resolution '1920x1080' -Fps $f } $Name $vm.Guest $Hz
"guest display at $Hz : $($set | ConvertTo-Json -Compress)" | Write-Host
if ("$($set.applied)" -notmatch "@$Hz$") { throw "The virtual display did not take $Hz Hz." }

$smooth = @(
    @{ Name = "$Hz-vsync"; Client = @{ fps = $Hz; vsync = $true; framePacing = $false } }
    @{ Name = "$Hz-novsync"; Client = @{ fps = $Hz; vsync = $false; framePacing = $false } }
    @{ Name = "$Hz-vsync-pacing"; Client = @{ fps = $Hz; vsync = $true; framePacing = $true } }
    @{ Name = '165-vsync'; Client = @{ fps = 165; vsync = $true; framePacing = $false } }
)
& (Join-Path $labs '021-stream-smoothness\run.ps1') -Name $Name -Rounds $Rounds -SkipLocal -Custom $smooth -Out (Join-Path $OutDir 'smoothness.json')

$latency = @(
    @{ Name = "$Hz-vsync"; Client = @{ displayMode = 'borderless'; fps = $Hz; vsync = $true; framePacing = $false } }
    @{ Name = "$Hz-novsync"; Client = @{ displayMode = 'borderless'; fps = $Hz; vsync = $false; framePacing = $false } }
    @{ Name = '120-vsync'; Client = @{ displayMode = 'borderless'; fps = 120; vsync = $true; framePacing = $false } }
    @{ Name = '120-novsync'; Client = @{ displayMode = 'borderless'; fps = 120; vsync = $false; framePacing = $false } }
)
& (Join-Path $labs '020-input-latency\run.ps1') -Name $Name -Rounds $Rounds -SkipLocal -Custom $latency -Out (Join-Path $OutDir 'input.json')

$log = & $vm.Module { param($a, $c) Invoke-SunshineApi -Address $a -Credential $c -Path '/api/logs' } $vm.Address $vm.Sunshine
Set-Content -LiteralPath (Join-Path $OutDir 'sunshine.log') -Value $log -Encoding utf8
"saved $OutDir" | Write-Host
