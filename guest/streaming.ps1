# Installs streaming inside the VM: virtual display (VDD) and Sunshine. Windows PowerShell 5.1.
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

# VB-CABLE is installed silently as allowed by its distribution license (https://vb-audio.com/Services/licensing.htm):
# permitted if the user can see it comes from VB-Audio and can donate. The package stays in C:\GpuVM\VB-CABLE with LEEME.txt.
# The driver has a Microsoft WHQL signature, so Windows does not prompt when installing it.
function Install-GpuVMAudio {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Root
    )
    $zip = Get-ChildItem $Dir -Filter 'VBCABLE*.zip' | Select-Object -First 1
    if (-not $zip) { return 'error: falta el paquete de VB-CABLE' }
    $package = Join-Path $Root 'VB-CABLE'
    Expand-Archive $zip.FullName -DestinationPath $package -Force
    Set-Content (Join-Path $package 'LEEME.txt') -Encoding UTF8 -Value @(
        'El audio de esta VM usa VB-CABLE, de VB-Audio Software (https://vb-cable.com).'
        'VB-CABLE es donationware: si te resulta útil, puedes apoyar a su autor en https://shop.vb-audio.com'
        'GpuVM lo instaló sin modificar el paquete original, que está en esta carpeta.'
    )

    $nefconDir = Join-Path $Dir 'nefcon'
    if (-not (Test-Path $nefconDir)) {
        $nefconZip = Get-ChildItem $Dir -Filter 'nefcon*.zip' | Select-Object -First 1
        if (-not $nefconZip) { return 'error: falta nefcon' }
        Expand-Archive $nefconZip.FullName -DestinationPath $nefconDir -Force
    }
    $nefcon = Get-ChildItem $nefconDir -Recurse -Filter 'nefconw.exe' | Where-Object { $_.Directory.Name -eq 'x64' } | Select-Object -First 1
    $inf = Join-Path $package 'vbMmeCable64_win10.inf'
    if (-not $nefcon -or -not (Test-Path $inf)) { return 'error: paquete de VB-CABLE o nefcon incompleto' }

    $p = Start-Process $nefcon.FullName -ArgumentList 'install', "`"$inf`"", 'VBAudioVACWDM' -Wait -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 5
    if (-not (Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -like 'VB-Audio Virtual Cable*' })) {
        return "error: nefcon terminó con código $($p.ExitCode) y el cable no aparece"
    }

    # Audio outputs show up after the restart; this task configures Sunshine at the next logon.
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $Root 'audio.ps1')`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
    Register-ScheduledTask -TaskName 'GpuVM-Audio' -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    'installed'
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
        if ($config.audio -eq 'vbcable') {
            Write-Host 'Instalando el audio (VB-CABLE)'
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
        Get-ChildItem $dir -File -Include *.msi, *.zip -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    $status
}
