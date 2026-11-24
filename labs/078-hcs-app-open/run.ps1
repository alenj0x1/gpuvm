# Lab 078: a machine without Hyper-V opened from the installed app the way a person does it: the machine in the
# sidebar, then its main button (Start and open / Open); passes when the viewer's picture is in front. Uses the mouse
# for a few seconds. The machine is made and removed with the installed module.
#   pwsh -NoProfile -File labs/078-hcs-app-open/run.ps1 [-Backend hyperv-gpup]
param([string]$Template = 'normal-tpl', [ValidateSet('hcs', 'hyperv-gpup')][string]$Backend = 'hcs', [int]$WaitSec = 300)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = $PSScriptRoot
$name = 'm078'; $lock = 'C:\GpuVM\.lab-lock'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $here 'out'; $null = New-Item -ItemType Directory -Force $outDir
$res = [ordered]@{ runId = $runId; backend = $Backend }
$sw = [Diagnostics.Stopwatch]::StartNew()
function Write-Log([string]$m) { Write-Host ("[{0,6:n1}s] {1}" -f $sw.Elapsed.TotalSeconds, $m) }
Import-Module (Join-Path $here '..\..\tests\e2e\E2E.psm1') -Force -DisableNameChecking
$module = Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force -PassThru -DisableNameChecking

try { $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) }
catch [IO.IOException] { throw "The lab lock is held: $(Get-Content $lock -Raw)" }
$fs.Write([Text.Encoding]::UTF8.GetBytes("lab078 pid=$PID $(Get-Date -Format o)")); $fs.Close()
try {
    if (-not (Get-App)) { Start-Process 'C:\Program Files\GpuVM\gpuvm.exe'; $null = Wait-For { Get-App } 30 }
    New-GpuVM -Name $name -Template $Template -Override @{ backend = $Backend } -Confirm:$false 6>$null | Out-Null
    Write-Log 'machine made'
    $root = Get-MainElement
    $row = $null; $null = Wait-For { $script:row = Find-Named (Get-MainElement) "^$name$"; [bool]$script:row } 30
    $res.rowFound = [bool]$row
    if (-not $row) { throw "the app doesn't list $name" }
    $null = Invoke-Element $row
    Start-Sleep 2
    $button = $null; $null = Wait-For { $script:button = Find-Named (Get-MainElement) '^(Start and open|Encender y abrir|Open|Abrir)$'; [bool]$script:button } 15
    $res.button = if ($button) { $button.Current.Name } else { $null }
    if (-not $button) { throw "no open button for $name" }
    $t = [Diagnostics.Stopwatch]::StartNew()
    $res.clicked = Click-Element $button
    if (-not $res.clicked) { $res.clicked = Invoke-Element $button }
    Write-Log "clicked '$($res.button)'"
    $res.picture = [bool](Wait-For {
            $p = Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $p) { return $false }
            foreach ($h in [E2E]::WindowsOf([uint32]$p.Id)) {
                $r = [E2E]::Rect($h)
                if ($r[2] -gt 400 -and $r[3] -gt 300 -and [E2E]::ProcessNameAt($r[0] + [int]($r[2] / 4), $r[1] + [int]($r[3] / 2)) -eq 'GpuVMViewer') { return $true }
            }
            $false
        } $WaitSec)
    $res.pictureSec = [math]::Round($t.Elapsed.TotalSeconds, 1)
    Write-Log "picture in front: $($res.picture) after $($res.pictureSec) s"
    if ($res.picture) {
        Start-Sleep 5
        $p = Get-Process GpuVMViewer | Select-Object -First 1
        $h = @([E2E]::WindowsOf([uint32]$p.Id) | Sort-Object { $r = [E2E]::Rect($_); - $r[2] * $r[3] })[0]
        $r = [E2E]::Rect($h)
        $bmp = Grab $r[0] $r[1] $r[2] $r[3]
        $colors = [Collections.Generic.HashSet[int]]::new()
        for ($x = 0; $x -lt $bmp.Width; $x += [math]::Max(1, [int]($bmp.Width / 40))) { for ($y = 0; $y -lt $bmp.Height; $y += [math]::Max(1, [int]($bmp.Height / 40))) { $null = $colors.Add($bmp.GetPixel($x, $y).ToArgb()) } }
        $res.pictureColors = $colors.Count
        $bmp.Save((Join-Path $outDir "$runId-picture.png")); $bmp.Dispose()
    }
} catch { $res.error = "$_"; $res.errorAt = $_.InvocationInfo.PositionMessage; Write-Log "FAILED: $_" }
finally {
    Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    try { Invoke-GpuVMPower -Name $name -Action TurnOff 6>$null | Out-Null } catch { }
    try { Remove-GpuVM -Name $name -DeleteDisk -Confirm:$false 6>$null | Out-Null } catch { $res.removeError = "$_" }
    $res.totalSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $res | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $outDir "$runId.json")
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
    Write-Log "done -> out/$runId.json; left behind: machine=$(Test-Path "C:\GpuVM\$name") lock=$(Test-Path $lock)"
}
