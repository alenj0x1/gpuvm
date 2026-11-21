# Lab 063: what the guest has for the lab (session user, browsers, Sunshine's helper, displays, GPU, VDD settings).
param([Parameter(Mandatory)][string]$Name)
. (Join-Path $PSScriptRoot 'common.ps1')
$cred = Get-Lab063Cred $Name
Invoke-Command -VMName $Name -Credential $cred {
    $user = (Get-CimInstance Win32_ComputerSystem).UserName
    $u = $user.Split('\')[-1]
    [ordered]@{
        user      = $user
        firefox   = @(Get-ChildItem "C:\Users\$u\AppData\Local\Mozilla Firefox\firefox.exe", 'C:\Program Files\Mozilla Firefox\firefox.exe' -ErrorAction SilentlyContinue).FullName
        edge      = @(Get-ChildItem 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' -ErrorAction SilentlyContinue).FullName
        procs     = @(Get-Process sunshine*, firefox, msedge -ErrorAction SilentlyContinue | Select-Object Name, Id, SessionId | ForEach-Object { "$($_.Name)/$($_.Id)/s$($_.SessionId)" })
        gpus      = @(Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name) | $($_.Status) | $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)@$($_.CurrentRefreshRate) | drv $($_.DriverVersion)" })
        vddGpu    = (Select-String -Path 'C:\VirtualDisplayDriver\vdd_settings.xml' -Pattern 'friendlyname|<gpu' -ErrorAction SilentlyContinue | ForEach-Object Line) -join ' '
        os        = (Get-CimInstance Win32_OperatingSystem).Version
        hags      = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode
        sunConf   = (Get-Content 'C:\Program Files\Sunshine\config\sunshine.conf' -ErrorAction SilentlyContinue) -join ' ; '
    }
} | ConvertTo-Json -Depth 4
