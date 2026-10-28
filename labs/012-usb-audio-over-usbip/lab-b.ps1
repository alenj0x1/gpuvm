# Lab 012, option B: a USB Audio Class speaker served by GpuVM over USB/IP inside the VM, driven by Windows' own
# usbaudio.sys, as Sunshine's sink. No questions asked; results go to out\lab-b-*.json.
# 1. Downloads usbip-win2 (pinned, SHA-256 checked) and installs only its client in the VM; checks that its drivers
#    are signed by Microsoft and that no root certificate was added.
# 2. Starts UsbAudioServer (127.0.0.1:3240 in the VM) and attaches it with usbip.exe.
# 3. Runs lab 011's measurement on the new output: loopback in the VM and Moonlight on this PC (Steam as control).
# The VM keeps usbip-win2 and the attached speaker for listening tests; lab-b-revert.ps1 removes all of it.
# Elevated, PowerShell 7: pwsh -File labs\012-usb-audio-over-usbip\lab-b.ps1
param(
    [string]$Name = (Get-VM | Where-Object Notes -like "Creada con GpuVM*" | Select-Object -First 1).Name,
    [string]$OutFile = (Join-Path $PSScriptRoot "out\lab-b-$(Get-Date -Format yyyyMMdd-HHmmss).json")
)
$ErrorActionPreference = 'Stop'
$usbip = [ordered]@{
    version = '0.9.8.0'
    url     = 'https://github.com/vadimgrn/usbip-win2/releases/download/v.0.9.8.0/USBip-0.9.8.0-x64.exe'
    sha256  = '81f426741f7ee2ed991febe24a22daca8400b6ae2f171054e3fb404897e15d39'
}
$guestDir = 'C:\GpuVM\lab012'
$report = [ordered]@{ vm = $Name; startedAt = (Get-Date).ToString('o'); usbip = $usbip }

Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$module = Get-Module GpuVM
if ((Get-VM -Name $Name).State -ne 'Running') { Connect-GpuVM -Name $Name; Start-Sleep -Seconds 20 }
$state = & $module { param($n) Get-GpuVMState -Name $n } $Name
$guest = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state

try {
    # 1. usbip-win2, verified before it goes anywhere.
    $installer = Join-Path $PSScriptRoot "out\USBip-$($usbip.version)-x64.exe"
    New-Item -ItemType Directory -Force (Split-Path $installer) | Out-Null
    if (-not (Test-Path $installer)) { Invoke-WebRequest $usbip.url -OutFile $installer }
    $hash = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $usbip.sha256) { Remove-Item $installer; throw "SHA-256 de usbip-win2 no coincide: $hash" }

    $session = New-PSSession -VMName $Name -Credential $guest
    try {
        Invoke-Command -Session $session -ArgumentList $guestDir -ScriptBlock { param($d) New-Item -ItemType Directory -Force $d | Out-Null }
        foreach ($file in $installer, (Join-Path $PSScriptRoot 'UsbAudioServer.cs'), (Join-Path $PSScriptRoot 'uac-server.ps1')) {
            Copy-Item $file -Destination $guestDir -ToSession $session -Force
        }
        $report.install = Invoke-Command -Session $session -ArgumentList $guestDir, (Split-Path $installer -Leaf) -ScriptBlock {
            param($dir, $exe)
            $find = { Get-ChildItem "$env:ProgramFiles\USBip*" -Recurse -Filter usbip.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
            $exePath = & $find
            $ran = $false
            if (-not $exePath) {
                # Only the client (UDE + filter drivers, usbip.exe) and the VC++ runtime usbip.exe needs.
                $p = Start-Process (Join-Path $dir $exe) -Wait -PassThru -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/COMPONENTS=main,client', '/TASKS=vcredist', "/LOG=$dir\install.log"
                $ran = $p.ExitCode
                $exePath = & $find
            }
            $drivers = @(Get-WindowsDriver -Online | Where-Object OriginalFileName -match 'usbip2_' | ForEach-Object {
                $cat = Get-ChildItem (Split-Path $_.OriginalFileName) -Filter *.cat | Select-Object -First 1
                $sig = Get-AuthenticodeSignature $cat.FullName
                [pscustomobject]@{ inf = Split-Path $_.OriginalFileName -Leaf; version = $_.Version; status = [string]$sig.Status; signer = $sig.SignerCertificate.Subject }
            })
            [pscustomobject]@{
                installerExit = $ran
                usbipExe = $exePath
                rootCertificates = @(Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -match 'usbip' } | ForEach-Object Subject)
                drivers = $drivers
                ude = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object InstanceId -like 'ROOT\USBIP_WIN2*' | ForEach-Object { "$($_.FriendlyName) $($_.Status)" })
            }
        } | Select-Object installerExit, usbipExe, rootCertificates, drivers, ude
        $report.install | Format-List | Out-Host
        if (-not $report.install.usbipExe) { throw 'usbip-win2 no quedó instalado.' }
        if ($report.install.rootCertificates) { throw "El instalador agregó un certificado raíz: $($report.install.rootCertificates -join ', ')" }
        if (@($report.install.drivers | Where-Object { $_.status -ne 'Valid' -or $_.signer -notmatch 'Microsoft' })) { throw 'Un driver de usbip-win2 no está firmado por Microsoft.' }

        # 2. Our server, then attach. The speaker shows up as a USB device driven by usbaudio.sys.
        $report.attach = Invoke-Command -Session $session -ArgumentList $guestDir, $report.install.usbipExe -ScriptBlock {
            param($dir, $usbipExe)
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\uac-server.ps1`""
            $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries
            Register-ScheduledTask -TaskName 'GpuVM-Lab012-UAC' -Action $action -User 'SYSTEM' -RunLevel Highest -Settings $settings -Force | Out-Null
            if ((Get-ScheduledTask -TaskName 'GpuVM-Lab012-UAC').State -ne 'Running') { Start-ScheduledTask -TaskName 'GpuVM-Lab012-UAC' }
            $deadline = (Get-Date).AddSeconds(30)
            while (-not (Get-NetTCPConnection -LocalPort 3240 -State Listen -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
            $out = if (Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object InstanceId -like 'USB\VID_1209&PID_0001*') { 'already attached' }
                   else { (& $usbipExe attach -r 127.0.0.1 -b 1-1 2>&1 | Out-String).Trim() }
            $endpoint = $null
            $deadline = (Get-Date).AddSeconds(45)
            while (-not $endpoint -and (Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 1
                $endpoint = Get-PnpDevice -Class AudioEndpoint -PresentOnly -ErrorAction SilentlyContinue |
                    Where-Object { $_.InstanceId -like 'SWD\MMDEVAPI\{0.0.0.*' -and $_.FriendlyName -like '*GpuVM Audio*' } | Select-Object -First 1
            }
            [pscustomobject]@{
                usbipOutput = $out
                usbDevices = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object InstanceId -like 'USB\VID_1209&PID_0001*' | ForEach-Object { "$($_.Class) $($_.FriendlyName) $($_.Status) $($_.InstanceId)" })
                endpoint = if ($endpoint) { "$($endpoint.FriendlyName) $($endpoint.Status)" } else { $null }
                server = Get-Content "$dir\status.json" -Raw -ErrorAction SilentlyContinue
                serverLog = @(Get-Content "$dir\server.log" -Tail 15 -ErrorAction SilentlyContinue)
            }
        } | Select-Object usbipOutput, usbDevices, endpoint, server, serverLog
        $report.attach | Format-List | Out-Host
        if (-not $report.attach.endpoint) { throw 'No apareció la salida de audio GpuVM Audio.' }
    }
    finally { Remove-PSSession $session -ErrorAction SilentlyContinue }

    # 3. Same measurement as lab 011, on the new output.
    $measureFile = $OutFile -replace '\.json$', '-measure.json'
    & (Join-Path $PSScriptRoot '..\011-audio-without-steam\lab-a.ps1') -Name $Name -Match '*GpuVM Audio*' -OutFile $measureFile
    $report.measure = Get-Content $measureFile -Raw | ConvertFrom-Json
    $report.serverAfter = Invoke-Command -VMName $Name -Credential $guest -ArgumentList $guestDir -ScriptBlock {
        param($dir) Get-Content "$dir\status.json" -Raw -ErrorAction SilentlyContinue
    }
}
catch { $report.error = "$($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)"; Write-Warning $report.error }
finally {
    $report.finishedAt = (Get-Date).ToString('o')
    New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
    $report | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 $OutFile
    Write-Host "`nResultado: $OutFile" -ForegroundColor Green
}
