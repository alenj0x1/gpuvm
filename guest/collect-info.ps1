# Run inside the VM to record its state before a benchmark. Windows PowerShell 5.1.
# Usage: powershell -ExecutionPolicy Bypass -File C:\GpuVM\collect-info.ps1
param([string]$OutDir = 'C:\GpuVM\bench')

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$nvidiaSmi = Get-ChildItem 'C:\Windows\System32\HostDriverStore\FileRepository' -Recurse -Filter nvidia-smi.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1
$smi = if ($nvidiaSmi) { & $nvidiaSmi.FullName --query-gpu=name,driver_version,memory.total,memory.used,utilization.gpu,clocks.gr,clocks.mem --format=csv 2>&1 | Out-String } else { $null }

$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$os = Get-CimInstance Win32_OperatingSystem
[pscustomobject]@{
    collectedAt  = (Get-Date).ToString('o')
    os           = "$($os.Caption) $($os.BuildNumber)"
    cpu          = $cpu.Name
    logicalCores = $cpu.NumberOfLogicalProcessors
    memoryGB     = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    powerPlan    = (powercfg.exe /getactivescheme | Out-String).Trim()
    gpus         = Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, Status, CurrentHorizontalResolution, CurrentVerticalResolution
    nvidiaSmi    = $smi
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutDir "info-$stamp.json") -Encoding UTF8

dxdiag.exe /t (Join-Path $OutDir "dxdiag-$stamp.txt")
Write-Host "Información guardada en $OutDir"
