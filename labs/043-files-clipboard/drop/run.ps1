<#
.SYNOPSIS
Lab 043 (drop): does an OLE drop from a Medium program reach a Low-integrity, restricted window in a job (the
viewer's sandbox), and can a Medium window of the app take the drop over once the viewer reports a drag?
Moves the mouse pointer for ~2 s per case over the probe's own windows (top-most); the source cancels the drag if
anything else is under the pointer. Results: out\drop-<time>.json.
#>
param([int]$Repeat = 3)
$ErrorActionPreference = 'Stop'
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$bin = 'C:\GpuVM-lab-043\drop'
New-Item -ItemType Directory -Force $bin | Out-Null
& $csc /nologo /target:winexe /out:"$bin\DropProbe.exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll (Join-Path $PSScriptRoot 'DropProbe.cs')
if ($LASTEXITCODE) { throw 'csc' }
$exe = "$bin\DropProbe.exe"
$file = "$bin\dropped.txt"; Set-Content $file 'lab 043'
Add-Type -AssemblyName System.Windows.Forms
$saved = [Windows.Forms.Cursor]::Position

$cases = @(
    @{ name = 'medium-target'; target = 'Medium'; accept = $true; overlay = $false }
    @{ name = 'low-target'; target = 'Low'; accept = $true; overlay = $false }
    @{ name = 'low-target+app-overlay'; target = 'Low'; accept = $false; overlay = $true }
)
$rows = @()
try {
    foreach ($round in 1..$Repeat) {
        foreach ($c in $cases) {
            $dir = Join-Path $env:USERPROFILE "AppData\LocalLow\GpuVM-lab-043\$($c.name)-$round"
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force $dir | Out-Null
            $procs = @()
            $targetArgs = @('launch', $c.target, $exe, 'target', $dir) + $(if ($c.accept) { 'accept' } else { @() })
            $procs += Start-Process $exe -ArgumentList $targetArgs -PassThru
            if ($c.overlay) { $procs += Start-Process $exe -ArgumentList @('launch', 'Medium', $exe, 'overlay', $dir) -PassThru }
            Start-Sleep -Milliseconds 1500
            $sourceArgs = @('launch', 'Medium', $exe, 'source', $dir, $file) + $(if ($c.overlay) { 'overlay' } else { @() })
            $src = Start-Process $exe -ArgumentList $sourceArgs -PassThru
            $src.WaitForExit(30000) | Out-Null
            Start-Sleep -Milliseconds 500
            Get-CimInstance Win32_Process -Filter "Name='DropProbe.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            $logs = @{}
            foreach ($r in 'target', 'overlay', 'source') { $p = Join-Path $dir "$r.log"; $logs[$r] = if (Test-Path $p) { @(Get-Content $p) } else { @() } }
            $row = [ordered]@{
                case = $c.name; round = $round
                targetIl = (($logs.target | Select-String 'il=(\S+)').Matches | Select-Object -First 1).Groups[1].Value
                targetEnter = [bool]($logs.target -match ' enter ')
                targetDrop = ($logs.target -match ' drop ' | Select-Object -First 1)
                overlayDrop = ($logs.overlay -match ' drop ' | Select-Object -First 1)
                source = ($logs.source -match ' done ' | Select-Object -First 1)
            }
            $rows += [pscustomobject]$row
            $row | ConvertTo-Json -Compress | Write-Host
        }
    }
}
finally {
    [Windows.Forms.Cursor]::Position = $saved
    Get-CimInstance Win32_Process -Filter "Name='DropProbe.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $out = Join-Path (Split-Path $PSScriptRoot) 'out'
    New-Item -ItemType Directory -Force $out | Out-Null
    $rows | ConvertTo-Json | Set-Content (Join-Path $out "drop-$(Get-Date -Format yyyyMMdd-HHmmss).json")
    Remove-Item (Join-Path $env:USERPROFILE 'AppData\LocalLow\GpuVM-lab-043') -Recurse -Force -ErrorAction SilentlyContinue
}
