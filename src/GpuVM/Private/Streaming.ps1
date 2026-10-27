$script:SunshineWebPort = 47990

function New-RandomPassword {
    param([int]$Length = 24)
    $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'.ToCharArray()
    $bytes = [byte[]]::new($Length)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

# Components the guest needs according to the profile's "streaming" section.
function Get-StreamingComponentNames {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Streaming)
    $names = @()
    if ($Streaming['provider'] -eq 'sunshine') { $names += 'sunshine' }
    if ($Streaming['virtualDisplay']) { $names += 'vdd' }
    if ($Streaming['audio'] -eq 'vbcable') { $names += 'vbcable' }
    # nefcon installs both the virtual display and the audio cable.
    if ($Streaming['virtualDisplay'] -or $Streaming['audio'] -eq 'vbcable') { $names += 'nefcon' }
    $names
}

# Prepares what is copied to the guest and what is saved in the host state.
# The Sunshine password travels in plain text to the guest (deleted after install) and is stored DPAPI-encrypted on the host.
function New-StreamingPayload {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $streaming = $Config['streaming']
    if (-not $streaming -or $streaming['provider'] -eq 'none') { return $null }

    $manifest = Get-ComponentManifest
    $files = foreach ($name in Get-StreamingComponentNames $streaming) {
        # The hash travels with the file so it can be re-verified right before copying it to the VM disk.
        @{ Source = Save-GpuVMComponent -Name $name -Manifest $manifest; Destination = 'streaming'; Sha256 = $manifest[$name]['sha256'] }
    }
    $user = 'gpuvm'
    $password = New-RandomPassword
    [pscustomobject]@{
        GuestFiles = @($files)
        GuestJson  = @{
            'streaming\streaming-config.json' = [ordered]@{
                provider           = $streaming['provider']
                user               = $user
                password           = $password
                gpuMatch           = $Config['gpu']['match']
                virtualDisplay     = [bool]$streaming['virtualDisplay']
                disableHyperVVideo = [bool]$streaming['disableHyperVVideo']
                audio              = $streaming['audio']
                sunshine           = $streaming['sunshine']
            }
        }
        State      = [ordered]@{
            provider     = $streaming['provider']
            user         = $user
            password     = ConvertTo-SecureString $password -AsPlainText -Force | ConvertFrom-SecureString
            pairedClient = $null
        }
    }
}

function Get-SunshineCredential {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    $s = $State['streaming']
    [pscredential]::new($s['user'], (ConvertTo-SecureString $s['password']))
}

function Get-GpuVMAddress {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutSec = 1200
    )
    # The first boot installs Windows and restarts once; the IP only shows up once Windows is running.
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $started = Get-Date
    $lastReport = [datetime]::MinValue
    do {
        $ip = Get-VMNetworkAdapter -VMName $Name |
            ForEach-Object IPAddresses |
            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' } |
            Select-Object -First 1
        if ($ip) { return $ip }
        if (((Get-Date) - $lastReport).TotalSeconds -ge 60) {
            $vm = Get-VM -Name $Name
            $heartbeat = (Get-VMIntegrationService -VMName $Name | Where-Object { $_.Id -like '*84EAAE65-2F2E-45F5-9BB5-0E857DC8EB47*' }).PrimaryStatusDescription
            Write-Step ("Esperando a que Windows arranque en '{0}' ({1:N0} min; estado {2}, CPU {3} %, latido {4}). Para ver la pantalla: vmconnect.exe localhost {0}" -f
                $Name, ((Get-Date) - $started).TotalMinutes, $vm.State, $vm.CPUUsage, ($heartbeat ? $heartbeat : 'sin datos'))
            $lastReport = Get-Date
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    throw "La VM '$Name' no obtuvo una dirección IP en $([int]($TimeoutSec / 60)) min. Mira su pantalla con: vmconnect.exe localhost $Name"
}

# Sunshine uses a self-signed certificate; it is accepted because the connection is to the local VM.
function Invoke-SunshineApi {
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][pscredential]$Credential,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        $Body
    )
    $params = @{
        Uri                  = "https://${Address}:$($script:SunshineWebPort)$Path"
        Method               = $Method
        Authentication       = 'Basic'
        Credential           = $Credential
        SkipCertificateCheck = $true
        TimeoutSec           = 15
    }
    if ($null -ne $Body) {
        $params['Body'] = $Body | ConvertTo-Json -Depth 5
        $params['ContentType'] = 'application/json'
    }
    Invoke-RestMethod @params
}

function Wait-SunshineReady {
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][pscredential]$Credential,
        [int]$TimeoutSec = 900
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $announced = $false
    while ($true) {
        try { Invoke-SunshineApi -Address $Address -Credential $Credential -Path '/api/clients/list' | Out-Null; return }
        catch {
            if ((Get-Date) -gt $deadline) { throw "Sunshine no responde en ${Address}:$($script:SunshineWebPort). Revisa C:\GpuVM\setup.log dentro de la VM. Último error: $_" }
            if (-not $announced) { Write-Step 'Esperando a Sunshine (el primer arranque instala Windows y el streaming; puede tardar varios minutos)'; $announced = $true }
            Start-Sleep -Seconds 10
        }
    }
}

# Sunshine logs the display list as JSON after "Currently available display devices:".
function ConvertFrom-SunshineDisplayLog {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)
    $start = ($Lines | Select-String 'Currently available display devices:' | Select-Object -Last 1).LineNumber
    if (-not $start) { return @() }
    $json = for ($i = $start; $i -lt $Lines.Count -and $Lines[$i] -notmatch '^\[\d{4}-'; $i++) { $Lines[$i] }
    @(($json -join "`n") | ConvertFrom-Json)
}

# With the Hyper-V display active, Sunshine captures the primary one (Hyper-V, no GPU) and Moonlight shows black.
# Pin the virtual display (EDID manufacturer "MTT") and ask for it to be the only active one while streaming.
function Set-SunshineVirtualDisplay {
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    $lines = (Invoke-SunshineApi -Address $Address -Credential $Credential -Path '/api/logs') -split "`n"
    $vdd = ConvertFrom-SunshineDisplayLog -Lines $lines | Where-Object { $_.edid -and $_.edid.manufacturer_id -eq 'MTT' } | Select-Object -First 1
    if (-not $vdd) { Write-Warning 'Sunshine no ve la pantalla virtual; la imagen puede salir en negro. Revisa C:\GpuVM\setup.log en la VM.'; return }

    $current = Invoke-SunshineApi -Address $Address -Credential $Credential -Path '/api/config'
    # /api/config only returns keys written in sunshine.conf; under StrictMode a missing one cannot be read.
    $currentOutput = $current.PSObject.Properties['output_name']?.Value
    $currentMode = $current.PSObject.Properties['dd_configuration_option']?.Value
    if ($currentOutput -eq $vdd.device_id -and $currentMode -eq 'ensure_only_display') { return }

    # /api/config replaces the whole file: resend the current keys plus the new ones.
    $settings = [ordered]@{}
    foreach ($prop in $current.PSObject.Properties) {
        if ($prop.Name -notin 'platform', 'status', 'version') { $settings[$prop.Name] = $prop.Value }
    }
    $settings['output_name'] = $vdd.device_id
    $settings['dd_configuration_option'] = 'ensure_only_display'
    Write-Step "Sunshine capturará la pantalla virtual ($($vdd.display_name))"
    Invoke-SunshineApi -Address $Address -Credential $Credential -Method POST -Path '/api/config' -Body $settings | Out-Null
    # Sunshine drops the connection when restarting; the error from that call is expected.
    try { Invoke-SunshineApi -Address $Address -Credential $Credential -Method POST -Path '/api/restart' -Body @{} | Out-Null } catch { }
    Start-Sleep -Seconds 5
    Wait-SunshineReady -Address $Address -Credential $Credential -TimeoutSec 120
}

# The first boot installs streaming and restarts the VM once. Pairing before that restart cuts it off halfway,
# so wait until the guest reports it is done (setup.done.json) and, if it asked to restart, until it has restarted.
function Wait-GuestReady {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        [int]$TimeoutSec = 1800
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $announced = $false
    while ((Get-Date) -lt $deadline) {
        $ready = try {
            Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock {
                $path = 'C:\GpuVM\setup.done.json'
                if (-not (Test-Path $path)) { return $false }
                $done = Get-Content -Raw $path | ConvertFrom-Json
                if ($done.PSObject.Properties['rebootPending'] -and -not $done.rebootPending) { return $true }
                (Get-CimInstance Win32_OperatingSystem).LastBootUpTime -gt (Get-Item $path).LastWriteTime
            }
        }
        catch { $false }
        if ($ready) { return }
        if (-not $announced) { Write-Step 'Windows termina de configurarse (solo la primera vez)'; $announced = $true }
        Start-Sleep -Seconds 10
    }
    Write-Warning 'La configuración inicial de la VM está tardando más de lo normal; se continúa igual.'
}

# Sets the virtual display to Moonlight's resolution and FPS. Runs in the user's session inside the VM
# (a scheduled task launched via PowerShell Direct), so it does not depend on Sunshine's display API.
# The script is sent every time, so it also works on VMs created with earlier versions.
function Set-GuestDisplayResolution {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$Resolution,
        [int]$Fps = 60
    )
    $width, $height = $Resolution.Split('x') | ForEach-Object { [int]$_ }
    $code = Get-Content -Raw -LiteralPath (Get-RepoPath 'guest\set-resolution.ps1')
    Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ArgumentList $code, $width, $height, $Fps -ScriptBlock {
        param($code, $width, $height, $fps)
        $script = 'C:\GpuVM\set-resolution.ps1'
        $out = 'C:\GpuVM\resolution.json'
        New-Item -ItemType Directory -Path 'C:\GpuVM' -Force | Out-Null
        Set-Content -Path $script -Value $code -Encoding UTF8
        Remove-Item $out -Force -ErrorAction SilentlyContinue
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        if (-not $user) { return [pscustomobject]@{ ok = $false; error = 'No hay una sesión iniciada en la pantalla.' } }
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Width $width -Height $height -Refresh $fps"
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName 'GpuVM-Resolution' -Action $action -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName 'GpuVM-Resolution'
        for ($i = 0; $i -lt 30 -and -not (Test-Path $out); $i++) { Start-Sleep -Milliseconds 500 }
        Unregister-ScheduledTask -TaskName 'GpuVM-Resolution' -Confirm:$false
        if (Test-Path $out) { Get-Content -Raw $out | ConvertFrom-Json } else { [pscustomobject]@{ ok = $false; error = 'La tarea no respondió.' } }
    }
}

# If the Hyper-V console (enhanced session) or Remote Desktop took the user's session, Sunshine
# only sees an empty screen. The session is returned to the console with tscon, run as SYSTEM inside the VM.
function Repair-GuestConsoleSession {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock {
        if (-not ('GpuVM.Wts' -as [type])) {
            Add-Type -Namespace GpuVM -Name Wts -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();'
        }
        $console = [GpuVM.Wts]::WTSGetActiveConsoleSessionId()
        $explorer = Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $explorer) { return 'no-session' }
        if ($explorer.SessionId -eq $console) { return 'ok' }
        $task = 'GpuVM-Console'
        $action = New-ScheduledTaskAction -Execute 'tscon.exe' -Argument "$($explorer.SessionId) /dest:console"
        Register-ScheduledTask -TaskName $task -Action $action -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
        Start-ScheduledTask -TaskName $task
        Start-Sleep -Seconds 3
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
        'moved'
    }
}

function Test-SunshineClientPaired {
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$ClientName
    )
    $clients = Invoke-SunshineApi -Address $Address -Credential $Credential -Path '/api/clients/list'
    ($clients | ConvertTo-Json -Depth 6) -match [regex]::Escape("`"$ClientName`"")
}

# Only Moonlight installed under Program Files is accepted: the app runs as administrator and Moonlight inherits that,
# so a Moonlight.exe from folders any user program can write to is never run.
function Get-MoonlightPath {
    @(
        (Join-Path $env:ProgramFiles 'Moonlight Game Streaming\Moonlight.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'Moonlight Game Streaming\Moonlight.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

# Moonlight starts pairing with a PIN; the PIN is handed to Sunshine through its API, without opening the web UI.
function Register-MoonlightPairing {
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$MoonlightPath,
        [Parameter(Mandatory)][string]$ClientName,
        [int]$TimeoutSec = 60
    )
    $pin = '{0:D4}' -f [Security.Cryptography.RandomNumberGenerator]::GetInt32(0, 10000)
    Write-Step "Emparejando Moonlight con Sunshine en $Address"
    $moonlight = Start-Process -FilePath $MoonlightPath -ArgumentList 'pair', $Address, '--pin', $pin -PassThru

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $submitted = $false
    while (-not $submitted -and (Get-Date) -lt $deadline -and -not $moonlight.HasExited) {
        $pending = @((Invoke-SunshineApi -Address $Address -Credential $Credential -Path '/api/pin').pairings)
        if ($pending.Count) {
            $request = $pending | Select-Object -Last 1
            $result = Invoke-SunshineApi -Address $Address -Credential $Credential -Method POST -Path '/api/pin' `
                -Body @{ pairing_id = $request.id; pin = $pin; name = $ClientName }
            if ($result.status -eq $false) { throw 'Sunshine rechazó el PIN de emparejamiento.' }
            $submitted = $true
        }
        else { Start-Sleep -Seconds 1 }
    }
    if (-not $submitted) { throw 'Moonlight no pidió emparejarse a tiempo.' }
    if (-not $moonlight.WaitForExit($TimeoutSec * 1000)) { throw 'Moonlight no terminó el emparejamiento.' }
    if ($moonlight.ExitCode -ne 0) { throw "Moonlight terminó el emparejamiento con código $($moonlight.ExitCode)." }
}

function Get-MoonlightStreamArguments {
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Client
    )
    # The app name is quoted; if it contained its own quotes it could inject arguments into Moonlight.
    if ($Client['app'] -notmatch '^[\w .-]{1,60}$') { throw "Nombre de app de Moonlight no válido: $($Client['app'])" }
    $arguments = @('stream', $Address, "`"$($Client['app'])`"")
    if ($Client['resolution']) { $arguments += '--resolution', $Client['resolution'] }
    if ($Client['fps']) { $arguments += '--fps', [string]$Client['fps'] }
    if ($Client['bitrateKbps']) { $arguments += '--bitrate', [string]$Client['bitrateKbps'] }
    if ($Client['codec'] -and $Client['codec'] -ne 'auto') { $arguments += '--video-codec', $Client['codec'] }
    # Latency settings: only passed if the profile defines them (undefined = Moonlight's default).
    $toggles = [ordered]@{ vsync = 'vsync'; framePacing = 'frame-pacing'; performanceOverlay = 'performance-overlay' }
    foreach ($key in $toggles.Keys) {
        if ($Client.Contains($key) -and $null -ne $Client[$key]) {
            $arguments += if ($Client[$key]) { "--$($toggles[$key])" } else { "--no-$($toggles[$key])" }
        }
    }
    if ($Client.Contains('displayMode') -and $Client['displayMode'] -in 'fullscreen', 'windowed', 'borderless') {
        $arguments += '--display-mode', $Client['displayMode']
    }
    $arguments
}
