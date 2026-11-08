# Lab 020: tells apart why an input sample missed. Opens Moonlight (borderless, V-Sync off), injects a few inputs of
# each kind and compares what the meter saw with what the target in the VM counted (its status file).
# Run elevated: pwsh -File labs/020-input-latency/diag.ps1 -Name win10
param(
    [string]$Name = 'win10',
    [int]$Each = 8,
    [string]$OutDir = (Join-Path $PSScriptRoot "out\diag-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$tools = Join-Path $PSScriptRoot '..\..\tools\latency'
. (Join-Path $tools 'common.ps1')
. (Join-Path $tools 'input-meter.ps1')
$vm = Get-LatencyVM -Name $Name
$state = & $vm.Module { param($n) Get-GpuVMState -Name $n } $Name
$client = [ordered]@{}
foreach ($k in $state['config']['streaming']['client'].Keys) { $client[$k] = $state['config']['streaming']['client'][$k] }
$client['displayMode'] = 'borderless'; $client['vsync'] = $false; $client['framePacing'] = $false
& (Join-Path $tools 'start-target.ps1') -Name $Name -Minutes 15 -Script input-target.ps1 | Write-Host

function Get-GuestStatus {
    Invoke-Command -VMName $Name -Credential $vm.Guest -ScriptBlock {
        Get-ChildItem C:\Users\*\AppData\Local\Temp\gpuvm-input-target.txt -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content
    }
}

$arguments = & $vm.Module { param($a, $c) Get-MoonlightStreamArguments -Address $a -Client $c } $vm.Address $client
Get-Process Moonlight -ErrorAction SilentlyContinue | Stop-Process -Force
$started = Get-Date
$process = Start-Process (Join-Path $env:ProgramFiles 'Moonlight Game Streaming\Moonlight.exe') -ArgumentList $arguments -PassThru
"first frame: $(Wait-LatencyStreamVisible -Since $started) s" | Write-Host
Start-Sleep -Seconds 5
$process.Refresh()
"Moonlight in front: $([GpuVMInputMeter]::BringToFront($process.MainWindowHandle))" | Write-Host
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
[void][GpuVMInputMeter]::SetCursorPos($screen.Width / 2, $screen.Height / 6)
Start-Sleep -Milliseconds 300
"guest before: $(Get-GuestStatus)" | Write-Host
Save-ScreenRegion -Path (Join-Path $OutDir '1-before.png')
foreach ($kind in 'click', 'key', 'move') {
    $index = @{ key = 0; click = 1; move = 2 }[$kind]
    $p = Get-InputSquarePoint -Bounds $screen -Index $index
    $times = for ($i = 0; $i -lt $Each; $i++) {
        $b = [GpuVMInputMeter]::Brightness($p.X, $p.Y)
        $ms = [GpuVMInputMeter]::Measure($index, $p.X, $p.Y, 500, $process.MainWindowHandle)
        "{0}:{1:N1}" -f $b, $ms
        Start-Sleep -Milliseconds 300
    }
    Start-Sleep -Milliseconds 1200
    "$kind  host (brightness before:ms) $($times -join ' ')  |  guest: $(Get-GuestStatus)" | Write-Host
    Save-ScreenRegion -Path (Join-Path $OutDir "2-after-$kind.png")
}
Stop-LatencyStream ([pscustomobject]@{ Process = $process }) -VM $vm
& (Join-Path $tools 'stop-target.ps1') -Name $Name | Write-Host
