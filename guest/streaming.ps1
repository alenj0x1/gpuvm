# Installs streaming inside the VM: virtual display (VDD), Sunshine and audio. Windows PowerShell 5.1.
# Called by setup.ps1 if C:\GpuVM\streaming\streaming-config.json exists.

function Install-GpuVMVirtualDisplay {
    param([Parameter(Mandatory)][string]$Dir)
    $work = Join-Path $Dir 'vdd'
    $zip = Get-ChildItem $Dir -Filter 'VirtualDisplayDriver*.zip' | Select-Object -First 1
    $nefconZip = Get-ChildItem $Dir -Filter 'nefcon*.zip' | Select-Object -First 1
    if (-not $zip -or -not $nefconZip) { return 'error: faltan los paquetes de VDD o nefcon' }
    Expand-Archive $zip.FullName -DestinationPath $work -Force
    Expand-Archive $nefconZip.FullName -DestinationPath (Join-Path $Dir 'nefcon') -Force

    $inf = Get-ChildItem $work -Recurse -Filter 'MttVDD.inf' | Select-Object -First 1
    $cat = Get-ChildItem $inf.DirectoryName -Filter '*.cat' | Select-Object -First 1
    $nefcon = Get-ChildItem (Join-Path $Dir 'nefcon') -Recurse -Filter 'nefconw.exe' | Where-Object { $_.Directory.Name -eq 'x64' } | Select-Object -First 1
    if (-not $inf -or -not $cat -or -not $nefcon) { return 'error: paquete de VDD incompleto' }

    # Only the certificate that signed the driver is trusted, so Windows installs it without prompting.
    $signer = (Get-AuthenticodeSignature $cat.FullName).SignerCertificate
    if (-not $signer) { return 'error: el catálogo del driver no está firmado' }
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
    "error: nefcon terminó con código $($p.ExitCode) y la pantalla virtual no aparece"
}

# Replaces or appends "key = value" in sunshine.conf.
function Set-SunshineConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings
    )
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path $Path) { foreach ($line in Get-Content $Path) { $lines.Add($line) } }
    foreach ($key in $Settings.Keys) {
        # A line break in a key or value would inject unintended configuration lines.
        if ("$key$($Settings[$key])" -match '[\r\n]') { throw "Valor no válido para sunshine.conf: $key" }
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
    if (-not $msi) { return 'error: falta el instalador de Sunshine' }
    $log = Join-Path (Split-Path $Dir -Parent) 'sunshine-install.log'
    $p = Start-Process msiexec.exe -ArgumentList '/i', "`"$($msi.FullName)`"", '/qn', '/norestart', '/l*v', "`"$log`"" -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010) { return "error: msiexec terminó con código $($p.ExitCode) (ver $log)" }

    $install = Join-Path $env:ProgramFiles 'Sunshine'
    $exe = Join-Path $install 'sunshine.exe'
    if (-not (Test-Path $exe)) { return "error: no se encontró $exe" }
    Push-Location $install
    try { & $exe --creds $Config.user $Config.password | Out-Null } finally { Pop-Location }

    $settings = [ordered]@{ origin_web_ui_allowed = 'lan' }
    $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -like "*$($Config.gpuMatch)*" } | Select-Object -First 1
    if ($gpu) {
        $settings['adapter_name'] = $gpu.Name
        if ($gpu.Name -match 'NVIDIA') { $settings['encoder'] = 'nvenc' }
    }
    if ($Config.sunshine) {
        foreach ($prop in $Config.sunshine.PSObject.Properties) { $settings[$prop.Name] = $prop.Value }
    }
    Set-SunshineConfig -Path (Join-Path $install 'config\sunshine.conf') -Settings $settings

    Get-Service | Where-Object { $_.Name -like 'Sunshine*' -or $_.DisplayName -like '*Sunshine*' } | Restart-Service -Force -ErrorAction SilentlyContinue
    'ok'
}

# With the Hyper-V display active, Windows and Sunshine may stick to it instead of the virtual one.
function Disable-GpuVMHyperVVideo {
    $devices = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object FriendlyName -like '*Hyper-V*')
    if (-not $devices) { return 'not-found' }
    $devices | Disable-PnpDevice -Confirm:$false -ErrorAction Stop
    'disabled'
}

# Restarts Sunshine in the capture mode it is in (guest\capture-mode.ps1): the user task for wgc, the service otherwise.
function Restart-GpuVMSunshine {
    $userTask = Get-ScheduledTask -TaskName 'GpuVM-Sunshine-User' -ErrorAction SilentlyContinue
    if ($userTask) {
        Stop-ScheduledTask -TaskName $userTask.TaskName -ErrorAction SilentlyContinue
        Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-ScheduledTask -TaskName $userTask.TaskName
        return
    }
    Get-Service | Where-Object { $_.Name -like 'Sunshine*' -or $_.DisplayName -like '*Sunshine*' } | Restart-Service -Force -ErrorAction SilentlyContinue
}

# Audio is GpuVM's own USB speaker (audio\UsbAudioServer.cs, proven in lab 012): a USB/IP server inside the VM that
# usbip-win2 attaches, so Windows drives it with its built-in usbaudio.sys and Sunshine captures it like any output.
# Nothing leaves the VM: the server listens on 127.0.0.1 only and runs as LOCAL SERVICE from Program Files (admins only).
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

# Attaches the speaker if usbip-win2 does not have it, once the server is listening.
function Connect-GpuVMAudioDevice {
    param([Parameter(Mandatory)][string]$Usbip)
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Get-NetTCPConnection -LocalPort $script:AudioPort -State Listen -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    if ((& $Usbip port 2>&1 | Out-String) -notmatch "usbip://127\.0\.0\.1:$($script:AudioPort)/1-1") {
        & $Usbip attach -r 127.0.0.1 -b 1-1 2>&1 | Out-Null
    }
}

# Installs usbip-win2 (client only), checks its drivers, builds the server and starts it, attaches the speaker and
# points Sunshine at it. $Dir has the usbip-win2 installer; $Root has audio\UsbAudioServer.cs. Needs no restart.
function Install-GpuVMAudio {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Root
    )
    $usbip = Get-GpuVMUsbipPath
    if (-not $usbip) {
        $installer = Get-ChildItem $Dir -Filter 'USBip-*.exe' | Select-Object -First 1
        if (-not $installer) { return 'error: falta el instalador de usbip-win2' }
        # Only the client: the UDE and filter drivers and usbip.exe, plus the VC++ runtime usbip.exe needs.
        $p = Start-Process $installer.FullName -Wait -PassThru -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
            '/COMPONENTS=main,client', '/TASKS=vcredist', "/LOG=`"$(Join-Path $Root 'usbip-install.log')`""
        $usbip = Get-GpuVMUsbipPath
        if (-not $usbip) { return "error: el instalador de usbip-win2 terminó con código $($p.ExitCode)" }
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
        return 'error: los drivers de usbip-win2 no están firmados por Microsoft; se desinstaló'
    }

    # The server is compiled here from its source and kept where only administrators can change it.
    Stop-ScheduledTask -TaskName $script:AudioTask -ErrorAction SilentlyContinue
    Get-Process GpuVMAudio -ErrorAction SilentlyContinue | Stop-Process -Force
    New-Item -ItemType Directory -Force $script:AudioProgramDir, $script:AudioDataDir | Out-Null
    $source = Join-Path $script:AudioProgramDir 'UsbAudioServer.cs'
    $exe = Join-Path $script:AudioProgramDir 'GpuVMAudio.exe'
    Copy-Item (Join-Path $Root 'audio\UsbAudioServer.cs') $source -Force
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
    Add-Type -Path $source -OutputAssembly $exe -OutputType ConsoleApplication
    if (-not (Test-Path $exe)) { return 'error: no se pudo compilar el servidor de audio' }
    # LOCAL SERVICE only writes its log and status.
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
    # Replaces the VB-CABLE logon task of older VMs, which had the same name.
    Register-ScheduledTask -TaskName $script:AudioTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $script:AudioTask

    Connect-GpuVMAudioDevice -Usbip $usbip
    # Persistent: usbip-win2 attaches it again every time its driver loads, so it is back after each restart.
    & $usbip port --stash 2>&1 | Out-Null
    $endpoint = Wait-GpuVMAudioEndpoint
    if (-not $endpoint) { return 'error: Windows no mostró la salida de audio GpuVM Audio' }

    # virtual_sink makes Sunshine switch the default output to the speaker while streaming.
    Set-SunshineConfig -Path (Join-Path $env:ProgramFiles 'Sunshine\config\sunshine.conf') -Settings ([ordered]@{ virtual_sink = $endpoint })
    Restart-GpuVMSunshine
    'ok'
}

# Run on every open (from the host, through PowerShell Direct): 'install' if the speaker is missing or its server is
# older than $SourceHash; otherwise makes sure it is running and attached. Returns 'ok', 'install' or 'error: …'.
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
    'error: la salida de audio GpuVM Audio no aparece'
}

function Install-GpuVMStreaming {
    param([string]$Root = 'C:\GpuVM')
    $dir = Join-Path $Root 'streaming'
    $configPath = Join-Path $dir 'streaming-config.json'
    $config = Get-Content -Raw -Encoding UTF8 $configPath | ConvertFrom-Json
    $status = [ordered]@{ provider = $config.provider; virtualDisplay = 'skipped'; sunshine = 'skipped'; hyperVVideo = 'kept'; audio = 'skipped' }
    try {
        if ($config.virtualDisplay) {
            Write-Host 'Instalando la pantalla virtual'
            $status.virtualDisplay = Install-GpuVMVirtualDisplay -Dir $dir
        }
        if ($config.provider -eq 'sunshine') {
            Write-Host 'Instalando Sunshine'
            $status.sunshine = Install-GpuVMSunshine -Dir $dir -Config $config
        }
        # "vbcable" is how profiles before 0.3 named the audio option.
        if ($config.audio -in 'usb', 'vbcable') {
            Write-Host 'Instalando el audio (altavoz USB de GpuVM)'
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
