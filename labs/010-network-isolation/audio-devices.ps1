# Read-only: which audio device Sunshine captures from, and which one Windows plays to, inside the VM.
# pwsh -File labs\010-network-isolation\audio-devices.ps1
param(
    [string]$Name = (Get-VM | Where-Object Notes -like "Creada con GpuVM*" | Select-Object -First 1).Name,
    [string]$OutFile = (Join-Path $PSScriptRoot "out\audio-devices-$(Get-Date -Format yyyyMMdd-HHmmss).json")
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$module = Get-Module GpuVM
$state = & $module { param($n) Get-GpuVMState -Name $n } $Name
$guest = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state

$report = Invoke-Command -VMName $Name -Credential $guest -ScriptBlock {
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
    $render = foreach ($key in Get-ChildItem $root) {
        $props = Get-ItemProperty (Join-Path $key.PSPath 'Properties') -ErrorAction SilentlyContinue
        [pscustomobject]@{
            id     = $key.PSChildName
            name   = "$($props.'{a45c254e-df1c-4efd-8020-67d146a850e0},2') ($($props.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6'))"
            state  = (Get-ItemProperty $key.PSPath).DeviceState  # 1 = active
        }
    }
    $conf = 'C:\Program Files\Sunshine\config\sunshine.conf'
    [pscustomobject]@{
        render       = @($render)
        sunshineConf = @(if (Test-Path $conf) { Get-Content $conf | Where-Object { $_ -match 'sink|audio' } })
        sessions     = @(Get-Content 'C:\Program Files\Sunshine\config\sunshine.log' -Tail 2000 | Select-String 'session|Audio|sink' | Select-Object -Last 25 | ForEach-Object Line)
        users        = @(quser 2>$null)
    }
}
New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
$report | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 $OutFile
$report.render | Format-Table -AutoSize
$report.sunshineConf
