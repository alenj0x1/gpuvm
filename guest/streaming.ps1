function Install-GpuVMVirtualDisplay {
    param([Parameter(Mandatory)][string]$Dir)
    $work = Join-Path $Dir 'vdd'
    $zip = Get-ChildItem $Dir -Filter 'VirtualDisplayDriver*.zip' | Select-Object -First 1
    $nefconZip = Get-ChildItem $Dir -Filter 'nefcon*.zip' | Select-Object -First 1
    if (-not $zip -or -not $nefconZip) { return 'error: the VDD or nefcon packages are missing' }
    Expand-Archive $zip.FullName -DestinationPath $work -Force
    Expand-Archive $nefconZip.FullName -DestinationPath (Join-Path $Dir 'nefcon') -Force

    $inf = Get-ChildItem $work -Recurse -Filter 'MttVDD.inf' | Select-Object -First 1
    $cat = Get-ChildItem $inf.DirectoryName -Filter '*.cat' | Select-Object -First 1
    $nefcon = Get-ChildItem (Join-Path $Dir 'nefcon') -Recurse -Filter 'nefconw.exe' | Where-Object { $_.Directory.Name -eq 'x64' } | Select-Object -First 1
    if (-not $inf -or -not $cat -or -not $nefcon) { return 'error: the VDD package is incomplete' }

    # Only the certificate that signed the driver is trusted, so Windows installs it without prompting.
    $signer = (Get-AuthenticodeSignature $cat.FullName).SignerCertificate
    if (-not $signer) { return 'error: the driver''s catalog isn''t signed' }
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher', 'LocalMachine')
    $store.Open('ReadWrite')
    $store.Add($signer)
    $store.Close()

    $settings = Get-ChildItem $work -Recurse -Filter 'vdd_settings.xml' | Select-Object -First 1
    if ($settings -and -not (Test-Path 'C:\VirtualDisplayDriver\vdd_settings.xml')) {
        New-Item -ItemType Directory 'C:\VirtualDisplayDriver' -Force | Out-Null
        Copy-Item $settings.FullName 'C:\VirtualDisplayDriver\vdd_settings.xml'
    }

    $p = Start-Process $nefcon.FullName -ArgumentList 'install', "`"$($inf.FullName)`"", 'Root\MttVDD' -Wait -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 10
    $device = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains 'Root\MttVDD' -or $_.FriendlyName -match 'Virtual Display' }
    if ($device | Where-Object Status -eq 'OK') { return 'ok' }
    "error: nefcon ended with code $($p.ExitCode) and the virtual display doesn't show up"
}

function Set-SunshineConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings
    )
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path $Path) { foreach ($line in Get-Content $Path) { $lines.Add($line) } }
    foreach ($key in $Settings.Keys) {
        # A line break in a key or value would inject unintended configuration lines.
        if ("$key$($Settings[$key])" -match '[\r\n]') { throw "Invalid value for sunshine.conf: $key" }
        $entry = "$key = $($Settings[$key])"
        $index = -1
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "^\s*$([regex]::Escape($key))\s*=") { $index = $i; break } }
        if ($index -ge 0) { $lines[$index] = $entry } else { $lines.Add($entry) }
    }
    Set-Content -Path $Path -Value $lines -Encoding ASCII
}

function Install-GpuVMSunshine {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)]$Config
    )
    $msi = Get-ChildItem $Dir -Filter 'Sunshine*.msi' | Select-Object -First 1
    if (-not $msi) { return 'error: the Sunshine installer is missing' }
    $log = Join-Path (Split-Path $Dir -Parent) 'sunshine-install.log'
    $p = Start-Process msiexec.exe -ArgumentList '/i', "`"$($msi.FullName)`"", '/qn', '/norestart', '/l*v', "`"$log`"" -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010) { return "error: msiexec ended with code $($p.ExitCode) (see $log)" }

    $install = Join-Path $env:ProgramFiles 'Sunshine'
    $exe = Join-Path $install 'sunshine.exe'
    if (-not (Test-Path $exe)) { return "error: $exe wasn't found" }
    $fork = Join-Path $Dir 'fork'
    if (-not (Test-Path (Join-Path $fork 'sunshine.exe')) -or -not (Test-Path (Join-Path $fork 'tools\sunshine_wgc_capture.exe'))) { return 'error: GpuVM''s Sunshine is missing' }
    Get-Service | Where-Object { $_.Name -like 'Sunshine*' -or $_.DisplayName -like '*Sunshine*' } | Stop-Service -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force
    New-Item -ItemType Directory -Force (Join-Path $install 'tools') | Out-Null
    Copy-Item -LiteralPath (Join-Path $fork 'sunshine.exe') -Destination $exe -Force
    Copy-Item -LiteralPath (Join-Path $fork 'tools\sunshine_wgc_capture.exe') -Destination (Join-Path $install 'tools\sunshine_wgc_capture.exe') -Force
    $configDir = Join-Path $install 'config'
    & icacls.exe $configDir /inheritance:d /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { return "error: couldn't change the permissions of $configDir" }
    # Users, ALL APPLICATION PACKAGES and ALL RESTRICTED APPLICATION PACKAGES.
    & icacls.exe $configDir /remove:g '*S-1-5-32-545' '*S-1-15-2-1' '*S-1-15-2-2' /T /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { return "error: couldn't take Users' access off $configDir" }
    Push-Location $install
    try { & $exe --creds $Config.user $Config.password | Out-Null } finally { Pop-Location }

    $settings = [ordered]@{ origin_web_ui_allowed = 'lan'; capture = 'wgc' }
    $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -like "*$($Config.gpuMatch)*" } | Select-Object -First 1
    if ($gpu) {
        $settings['adapter_name'] = $gpu.Name
        # Without NVENC's quarter-resolution first pass: ~1.1 ms less from capture to packet.
        if ($gpu.Name -match 'NVIDIA') { $settings['encoder'] = 'nvenc'; $settings['nvenc_twopass'] = 'disabled' }
    }
    if ($Config.sunshine) {
        foreach ($prop in $Config.sunshine.PSObject.Properties) { $settings[$prop.Name] = $prop.Value }
    }
    Set-SunshineConfig -Path (Join-Path $install 'config\sunshine.conf') -Settings $settings

    Get-Service | Where-Object { $_.Name -like 'Sunshine*' -or $_.DisplayName -like '*Sunshine*' } | Restart-Service -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    'ok'
}

# With the Hyper-V display active, Windows and Sunshine may stick to it instead of the virtual one.
function Disable-GpuVMHyperVVideo {
    $devices = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object FriendlyName -like '*Hyper-V*')
    if (-not $devices) { return 'not-found' }
    $devices | Disable-PnpDevice -Confirm:$false -ErrorAction Stop
    'disabled'
}

function Restart-GpuVMSunshine {
    Get-Service | Where-Object { $_.Name -like 'Sunshine*' -or $_.DisplayName -like '*Sunshine*' } | Restart-Service -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
}

# The server listens on 127.0.0.1 only and runs as LOCAL SERVICE.
$script:AudioTask = 'GpuVM-Audio'
$script:AudioPort = 3240
$script:AudioProgramDir = Join-Path $env:ProgramFiles 'GpuVM\Audio'
$script:AudioDataDir = Join-Path $env:ProgramData 'GpuVM\Audio'

function Get-GpuVMUsbipPath {
    Get-ChildItem "$env:ProgramFiles\USBip*" -Recurse -Filter usbip.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}

# Windows localizes the output's name ("Speakers (GpuVM Audio)", "Altavoces (GpuVM Audio)"); the device name is ours.
function Get-GpuVMAudioEndpoint {
    Get-PnpDevice -Class AudioEndpoint -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'SWD\MMDEVAPI\{0.0.0.*' -and $_.FriendlyName -like '*GpuVM Audio*' -and $_.Status -eq 'OK' } |
        Select-Object -First 1 -ExpandProperty FriendlyName
}

function Wait-GpuVMAudioEndpoint {
    param([int]$Seconds = 45)
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $endpoint = Get-GpuVMAudioEndpoint
        if ($endpoint) { return $endpoint }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
}

function Connect-GpuVMAudioDevice {
    param([Parameter(Mandatory)][string]$Usbip)
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Get-NetTCPConnection -LocalPort $script:AudioPort -State Listen -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    if ((& $Usbip port 2>&1 | Out-String) -notmatch "usbip://127\.0\.0\.1:$($script:AudioPort)/1-1") {
        & $Usbip attach -r 127.0.0.1 -b 1-1 2>&1 | Out-Null
    }
}

function Install-GpuVMAudio {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Root
    )
    $usbip = Get-GpuVMUsbipPath
    if (-not $usbip) {
        $installer = Get-ChildItem $Dir -Filter 'USBip-*.exe' | Select-Object -First 1
        if (-not $installer) { return 'error: the usbip-win2 installer is missing' }
        $p = Start-Process $installer.FullName -Wait -PassThru -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
            '/COMPONENTS=main,client', '/TASKS=vcredist', "/LOG=`"$(Join-Path $Root 'usbip-install.log')`""
        $usbip = Get-GpuVMUsbipPath
        if (-not $usbip) { return "error: the usbip-win2 installer ended with code $($p.ExitCode)" }
    }

    # Its drivers must be signed by Microsoft and it must not have trusted any certificate of its own.
    $drivers = @(Get-WindowsDriver -Online | Where-Object OriginalFileName -match 'usbip2_')
    $unsigned = @($drivers | ForEach-Object {
        $cat = Get-ChildItem (Split-Path $_.OriginalFileName) -Filter *.cat | Select-Object -First 1
        $sig = if ($cat) { Get-AuthenticodeSignature $cat.FullName }
        if (-not $sig -or $sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft') { $_.OriginalFileName }
    })
    $trusted = @(Get-ChildItem Cert:\LocalMachine\Root, Cert:\LocalMachine\TrustedPublisher | Where-Object Subject -match 'usbip')
    if (-not $drivers -or $unsigned -or $trusted) {
        $uninstaller = Get-ChildItem (Split-Path $usbip) -Filter 'unins*.exe' | Select-Object -First 1
        if ($uninstaller) { Start-Process $uninstaller.FullName -Wait -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' }
        return 'error: the usbip-win2 drivers aren''t signed by Microsoft; it was uninstalled'
    }

    Stop-ScheduledTask -TaskName $script:AudioTask -ErrorAction SilentlyContinue
    Get-Process GpuVMAudio -ErrorAction SilentlyContinue | Stop-Process -Force
    New-Item -ItemType Directory -Force $script:AudioProgramDir, $script:AudioDataDir | Out-Null
    $source = Join-Path $script:AudioProgramDir 'UsbAudioServer.cs'
    $exe = Join-Path $script:AudioProgramDir 'GpuVMAudio.exe'
    Copy-Item (Join-Path $Root 'audio\UsbAudioServer.cs') $source -Force
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
    Add-Type -Path $source -OutputAssembly $exe -OutputType ConsoleApplication
    if (-not (Test-Path $exe)) { return 'error: the audio server couldn''t be built' }
    icacls.exe $script:AudioDataDir /grant '*S-1-5-19:(OI)(CI)M' | Out-Null

    $log = Join-Path $script:AudioDataDir 'server.log'
    $status = Join-Path $script:AudioDataDir 'status.json'
    $action = New-ScheduledTaskAction -Execute $exe -Argument "$($script:AudioPort) `"$log`" `"$status`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\LOCAL SERVICE' -LogonType ServiceAccount
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    # Above normal (tasks default to below normal): the server is the speaker's clock.
    $settings.Priority = 2
    Register-ScheduledTask -TaskName $script:AudioTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $script:AudioTask

    Connect-GpuVMAudioDevice -Usbip $usbip
    # --stash: usbip-win2 attaches it again every time its driver loads.
    & $usbip port --stash 2>&1 | Out-Null
    $endpoint = Wait-GpuVMAudioEndpoint
    if (-not $endpoint) { return 'error: Windows didn''t show the GpuVM Audio output' }

    Set-SunshineConfig -Path (Join-Path $env:ProgramFiles 'Sunshine\config\sunshine.conf') -Settings ([ordered]@{ virtual_sink = $endpoint })
    Restart-GpuVMSunshine
    'ok'
}

function Repair-GpuVMAudio {
    param([Parameter(Mandatory)][string]$SourceHash)
    $usbip = Get-GpuVMUsbipPath
    $source = Join-Path $script:AudioProgramDir 'UsbAudioServer.cs'
    $task = Get-ScheduledTask -TaskName $script:AudioTask -ErrorAction SilentlyContinue
    $current = $usbip -and $task -and $task.Principal.UserId -match 'LOCAL SERVICE' -and
        (Test-Path (Join-Path $script:AudioProgramDir 'GpuVMAudio.exe')) -and (Test-Path $source) -and
        (Get-FileHash $source -Algorithm SHA256).Hash -eq $SourceHash
    if (-not $current) { return 'install' }
    if (Get-GpuVMAudioEndpoint) { return 'ok' }
    # Right after boot usbip-win2 may still be attaching it; if not, attach it again.
    if ($task.State -ne 'Running') { Start-ScheduledTask -TaskName $script:AudioTask }
    if (Wait-GpuVMAudioEndpoint -Seconds 10) { return 'ok' }
    Connect-GpuVMAudioDevice -Usbip $usbip
    if (Wait-GpuVMAudioEndpoint) { return 'ok' }
    'error: the GpuVM Audio output doesn''t show up'
}

function Install-GpuVMStreaming {
    param([string]$Root = 'C:\GpuVM')
    $dir = Join-Path $Root 'streaming'
    $configPath = Join-Path $dir 'streaming-config.json'
    $config = Get-Content -Raw -Encoding UTF8 $configPath | ConvertFrom-Json
    $status = [ordered]@{ provider = $config.provider; virtualDisplay = 'skipped'; sunshine = 'skipped'; hyperVVideo = 'kept'; audio = 'skipped' }
    try {
        if ($config.virtualDisplay) {
            Write-Host 'Installing the virtual display'
            $status.virtualDisplay = Install-GpuVMVirtualDisplay -Dir $dir
        }
        if ($config.provider -eq 'sunshine') {
            Write-Host 'Installing Sunshine'
            $status.sunshine = Install-GpuVMSunshine -Dir $dir -Config $config
        }
        # "vbcable" is how profiles before 0.3 named the audio option.
        if ($config.audio -in 'usb', 'vbcable') {
            Write-Host 'Installing the audio (GpuVM''s USB speaker)'
            $status.audio = Install-GpuVMAudio -Dir $dir -Root $Root
        }
        # Only disable the Hyper-V display if the virtual one is working; otherwise the VM would have no display.
        if ($config.disableHyperVVideo -and $status.virtualDisplay -eq 'ok') {
            $status.hyperVVideo = Disable-GpuVMHyperVVideo
        }
    }
    catch {
        $status['error'] = "$_"
    }
    finally {
        # The file holds the Sunshine password; the installers are no longer needed.
        Remove-Item $configPath -Force -ErrorAction SilentlyContinue
        Get-ChildItem $dir -File -Include *.msi, *.zip, *.exe -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    $status
}
