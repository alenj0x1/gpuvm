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
    if (Test-GpuVMAudio $Streaming) { $names += 'usbip' }
    if ($Streaming['virtualDisplay']) { $names += 'nefcon' }
    $names
}

# Whether the VM has GpuVM's USB speaker. "vbcable" is how VMs created before 0.3 named it; they move to the speaker on open.
function Test-GpuVMAudio {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Streaming)
    $Streaming['audio'] -in 'usb', 'vbcable'
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

# Values that come from the guest (PowerShell Direct, KVP) are untrusted: only a string of bounded length
# without control characters is kept; anything else (objects, arrays) becomes ''.
function ConvertTo-GuestString {
    param($Value, [int]$MaxLength = 200)
    if ($Value -isnot [string] -and $Value -isnot [ValueType]) { return '' }
    $text = ([string]$Value) -replace '\p{C}', ' '
    if ($text.Length -gt $MaxLength) { $text = $text.Substring(0, $MaxLength) }
    $text
}

# Dotted IPv4 ("172.20.1.5") to a number; $null if it is anything else.
function ConvertTo-IPv4Number {
    param([AllowEmptyString()][string]$Address)
    if ($Address -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $null }
    $number = [int64]0
    foreach ($i in 1..4) {
        $octet = [int]$Matches[$i]
        if ($octet -gt 255) { return $null }
        $number = $number * 256 + $octet
    }
    $number
}

# The guest reports its own IP (KVP), so it could point the host at any machine. It is only accepted if it is an
# IPv4 host address of the subnet of the host's adapter on the VM's switch, and not the host itself.
function Test-GuestAddressInHostSubnet {
    param(
        [AllowEmptyString()][string]$Address,
        [Parameter(Mandatory)][string]$HostAddress,
        [Parameter(Mandatory)][ValidateRange(1, 32)][int]$PrefixLength
    )
    $guest = ConvertTo-IPv4Number $Address
    $hostIp = ConvertTo-IPv4Number $HostAddress
    if ($null -eq $guest -or $null -eq $hostIp -or $guest -eq $hostIp) { return $false }
    $hostBits = ([int64]1 -shl (32 - $PrefixLength)) - 1
    if (($guest -bor $hostBits) -ne ($hostIp -bor $hostBits)) { return $false }
    # Network and broadcast addresses are not hosts (/31 and /32 have neither).
    if ($PrefixLength -le 30 -and (($guest -band $hostBits) -eq 0 -or ($guest -band $hostBits) -eq $hostBits)) { return $false }
    $true
}

# The host's IPv4 addresses on the switch the VM is connected to (its "vEthernet (<switch>)" adapter).
function Get-GpuVMHostNetwork {
    param([Parameter(Mandatory)][string]$Name)
    $switch = (Get-VMNetworkAdapter -VMName $Name | Select-Object -First 1).SwitchName
    if (-not $switch) { throw "La VM '$Name' no está conectada a ningún conmutador virtual." }
    $networks = @(Get-NetIPAddress -InterfaceAlias "vEthernet ($switch)" -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' } |
        ForEach-Object { [pscustomobject]@{ Address = $_.IPAddress; PrefixLength = [int]$_.PrefixLength } })
    if (-not $networks) { throw "El host no tiene una dirección IPv4 en el conmutador '$switch' de la VM '$Name'; no se puede comprobar la IP que informa la VM." }
    $networks
}

# The VM's IP and the host's IP on the same subnet (the address Moonlight connects from).
function Get-GpuVMEndpoint {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutSec = 1200
    )
    $networks = Get-GpuVMHostNetwork -Name $Name
    # The first boot installs Windows and restarts once; the IP only shows up once Windows is running.
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $started = Get-Date
    $lastReport = [datetime]::MinValue
    do {
        $reported = @(Get-VMNetworkAdapter -VMName $Name |
            ForEach-Object IPAddresses |
            Where-Object { $null -ne (ConvertTo-IPv4Number ([string]$_)) -and $_ -notlike '169.254.*' })
        foreach ($ip in $reported) {
            foreach ($network in $networks) {
                if (Test-GuestAddressInHostSubnet -Address $ip -HostAddress $network.Address -PrefixLength $network.PrefixLength) {
                    return [pscustomobject]@{ Address = [string]$ip; HostAddress = $network.Address }
                }
            }
        }
        if ($reported) {
            $subnets = ($networks | ForEach-Object { "$($_.Address)/$($_.PrefixLength)" }) -join ', '
            throw ("La VM '{0}' informa la IP {1}, que no está en la red del host con la VM ({2}). Por seguridad no se conecta: revisa el adaptador de red de la VM." -f
                $Name, (ConvertTo-GuestString ($reported -join ', ') -MaxLength 100), $subnets)
        }
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

function Get-GpuVMAddress {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutSec = 1200
    )
    (Get-GpuVMEndpoint -Name $Name -TimeoutSec $TimeoutSec).Address
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
        # A redirect would send the credentials somewhere the guest chose.
        MaximumRedirection   = 0
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
        [int]$TimeoutSec = 900,
        # What is shown while waiting: only the caller knows whether this is the first boot or just a restart.
        [string]$Message = 'Esperando a que Sunshine responda'
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $announced = $false
    while ($true) {
        try { Invoke-SunshineApi -Address $Address -Credential $Credential -Path '/api/clients/list' | Out-Null; return }
        catch {
            if ((Get-Date) -gt $deadline) { throw "Sunshine no responde en ${Address}:$($script:SunshineWebPort). Revisa C:\GpuVM\setup.log dentro de la VM. Último error: $_" }
            if (-not $announced) { Write-Step $Message; $announced = $true }
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
# Pin the virtual display (EDID manufacturer "MTT"). If the Hyper-V display is still there, Sunshine is asked to keep
# the virtual one as the only active display while streaming. If GpuVM already disabled it (-OnlyDisplay), Sunshine is
# told not to touch displays: any change it makes per session forces it to re-test every encoder, and the first frame
# then takes 15 to 25 s instead of about 2 s (lab 008).
function Set-SunshineVirtualDisplay {
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][pscredential]$Credential,
        [switch]$OnlyDisplay
    )
    $lines = (Invoke-SunshineApi -Address $Address -Credential $Credential -Path '/api/logs') -split "`n"
    $vdd = ConvertFrom-SunshineDisplayLog -Lines $lines | Where-Object { $_.edid -and $_.edid.manufacturer_id -eq 'MTT' } | Select-Object -First 1
    if (-not $vdd) { Write-Warning 'Sunshine no ve la pantalla virtual; la imagen puede salir en negro. Revisa C:\GpuVM\setup.log en la VM.'; return }

    $mode = if ($OnlyDisplay) { 'disabled' } else { 'ensure_only_display' }
    $settings = [ordered]@{ output_name = $vdd.device_id; dd_configuration_option = $mode }
    if (Update-SunshineConfig -Address $Address -Credential $Credential -Settings $settings) {
        Write-Step "Sunshine capturará la pantalla virtual ($($vdd.display_name))"
    }
}

# Writes keys to sunshine.conf through the API and restarts Sunshine, only if something changes.
# Returns $true when it changed the configuration.
function Update-SunshineConfig {
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings
    )
    $current = Invoke-SunshineApi -Address $Address -Credential $Credential -Path '/api/config'
    # /api/config only returns keys written in sunshine.conf; under StrictMode a missing one cannot be read.
    $changed = @($Settings.Keys | Where-Object { $current.PSObject.Properties[$_]?.Value -ne $Settings[$_] })
    if (-not $changed) { return $false }

    # /api/config replaces the whole file: resend the current keys plus the new ones.
    $body = [ordered]@{}
    foreach ($prop in $current.PSObject.Properties) {
        if ($prop.Name -notin 'platform', 'status', 'version') { $body[$prop.Name] = $prop.Value }
    }
    foreach ($key in $Settings.Keys) { $body[$key] = $Settings[$key] }
    Invoke-SunshineApi -Address $Address -Credential $Credential -Method POST -Path '/api/config' -Body $body | Out-Null
    # Sunshine drops the connection when restarting; the error from that call is expected.
    try { Invoke-SunshineApi -Address $Address -Credential $Credential -Method POST -Path '/api/restart' -Body @{} | Out-Null } catch { }
    Start-Sleep -Seconds 5
    Wait-SunshineReady -Address $Address -Credential $Credential -TimeoutSec 120 -Message 'Sunshine se reinicia con la configuración nueva'
    $true
}

# GpuVM's USB speaker in the guest (guest\audio, lab 012). The guest code is sent every time, so this installs it on
# VMs created before it existed (they had VB-CABLE, whose capture is silent in a VM), updates its server when the
# source changes, and attaches it again if Windows lost it. Returns $true when it installed it (Sunshine was restarted).
function Install-GuestAudio {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    $code = Get-Content -Raw -LiteralPath (Get-RepoPath 'guest\streaming.ps1')
    $server = Get-RepoPath 'guest\audio\UsbAudioServer.cs'
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $server).Hash
    $answer = Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ArgumentList $code, $hash -ScriptBlock {
        param($code, $hash)
        . ([scriptblock]::Create($code))
        Repair-GpuVMAudio -SourceHash $hash
    }
    $answer = ConvertTo-GuestString (@($answer)[-1])
    $installed = $answer -eq 'install'
    if ($installed) {
        Write-Step 'Instalando el audio de la VM'
        $installer = Save-GpuVMComponent -Name 'usbip'
        $session = New-PSSession -VMName $Name -Credential $Credential -ErrorAction Stop
        try {
            Invoke-Command -Session $session { New-Item -ItemType Directory -Force 'C:\GpuVM\audio', 'C:\GpuVM\streaming' | Out-Null }
            Copy-Item -LiteralPath $installer -Destination 'C:\GpuVM\streaming' -ToSession $session -Force
            Copy-Item -LiteralPath $server -Destination 'C:\GpuVM\audio' -ToSession $session -Force
            $answer = Invoke-Command -Session $session -ErrorAction Stop -ArgumentList $code, (Split-Path $installer -Leaf) -ScriptBlock {
                param($code, $file)
                . ([scriptblock]::Create($code))
                try { Install-GpuVMAudio -Dir 'C:\GpuVM\streaming' -Root 'C:\GpuVM' }
                finally { Remove-Item (Join-Path 'C:\GpuVM\streaming' $file) -Force -ErrorAction SilentlyContinue }
            }
            $answer = ConvertTo-GuestString (@($answer)[-1])
        }
        finally { Remove-PSSession $session -ErrorAction SilentlyContinue }
    }
    if ($answer -ne 'ok') { throw "El audio de la VM no quedó listo: $answer" }
    $installed
}

# Name of GpuVM's speaker inside the guest. Windows localizes it ("Speakers (GpuVM Audio)", "Altavoces (GpuVM Audio)"),
# so it is found by being a render endpoint ({0.0.0.…}) of the device we name.
function Get-GuestAudioSink {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    $sink = Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock {
        Get-PnpDevice -Class AudioEndpoint -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -like 'SWD\MMDEVAPI\{0.0.0.*' -and $_.FriendlyName -like '*GpuVM Audio*' -and $_.Status -eq 'OK' } |
            Select-Object -First 1 -ExpandProperty FriendlyName
    }
    ConvertTo-GuestString (@($sink)[0]) -MaxLength 128
}

# Makes Sunshine capture GpuVM's speaker (virtual_sink), in case its name changed or the install could not set it.
function Set-SunshineAudioSink {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    $sink = Get-GuestAudioSink -Name $Name -Credential $GuestCredential
    if (-not $sink) { Write-Warning 'No se encontró la salida de audio GpuVM Audio en la VM; la imagen se verá sin sonido.'; return }
    if (Update-SunshineConfig -Address $Address -Credential $Credential -Settings ([ordered]@{ virtual_sink = $sink })) {
        Write-Step "Sunshine captura el audio de $sink"
    }
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
    $announced = $null
    while ((Get-Date) -lt $deadline) {
        # Only a single real $true counts (the guest could return any object that is "truthy").
        # @() outside the try: assigning a try block unrolls the array (one item becomes a scalar, none becomes $null).
        $answer = @(try {
            Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock {
                $path = 'C:\GpuVM\setup.done.json'
                if (-not (Test-Path $path)) { return $false }
                $done = Get-Content -Raw $path | ConvertFrom-Json
                if ($done.PSObject.Properties['rebootPending'] -and -not $done.rebootPending) { return $true }
                (Get-CimInstance Win32_OperatingSystem).LastBootUpTime -gt (Get-Item $path).LastWriteTime
            }
        }
        catch { })
        $ready = $answer.Count -eq 1 -and $answer[0] -is [bool] -and $answer[0]
        if ($ready) { return }
        # No answer is Windows still booting; an answer of "not done" is the first-time setup.
        $message = if ($answer.Count) { 'Windows termina de configurarse (solo la primera vez)' } else { 'Esperando a que Windows arranque' }
        if ($announced -ne $message) { Write-Step $message; $announced = $message }
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
    $raw = Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ArgumentList $code, $width, $height, $Fps -ScriptBlock {
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
    # The answer is rebuilt from primitives only: it comes from the guest and ends up in messages on the host.
    $raw = @($raw)[0]
    $field = { param($key) if ($null -ne $raw -and $raw.PSObject.Properties[$key]) { $raw.$key } }
    $ok = & $field 'ok'
    $result = [pscustomobject]@{
        ok      = $ok -is [bool] -and $ok
        applied = ConvertTo-GuestString (& $field 'applied') -MaxLength 40
        error   = ConvertTo-GuestString (& $field 'error')
    }
    if ($null -ne $raw -and $raw.PSObject.Properties['available']) {
        $result | Add-Member NoteProperty available (ConvertTo-GuestString $raw.available -MaxLength 400)
    }
    $result
}

# If the Hyper-V console (enhanced session) or Remote Desktop took the user's session, Sunshine
# only sees an empty screen. The session is returned to the console with tscon, run as SYSTEM inside the VM.
function Repair-GuestConsoleSession {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    $status = Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock {
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
    ConvertTo-GuestString (@($status)[0]) -MaxLength 20
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

# Only Moonlight installed under Program Files is accepted: the app runs as administrator and decides which
# program to launch, so a Moonlight.exe from folders any user program can write to is never chosen.
function Get-MoonlightPath {
    @(
        (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Moonlight Game Streaming\Moonlight.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'Moonlight Game Streaming\Moonlight.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

# Moonlight talks to a server the guest controls, so it never runs elevated: it starts as the interactive
# user through a one-shot scheduled task (Limited run level). Returns the task name.
# With -KeepTask the task stays registered so the caller can follow it (Get-UnelevatedTaskState) and remove it.
function Start-UnelevatedProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList,
        [switch]$KeepTask
    )
    $taskName = "Moonlight-$([guid]::NewGuid().ToString('n'))"
    $actionParams = @{ Execute = $FilePath }
    if ($ArgumentList) { $actionParams['Argument'] = $ArgumentList -join ' ' }
    $action = New-ScheduledTaskAction @actionParams
    # The user signed in at the console: if GpuVM was elevated with another administrator account, that account has
    # no desktop session and the task would never show Moonlight.
    $user = (Get-CimInstance Win32_ComputerSystem).UserName
    if (-not $user) { $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name }
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    # No time limit: a streaming session can last hours.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $taskName -TaskPath '\GpuVM\' -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $taskName -TaskPath '\GpuVM\'
        # Wait until the process has started; removing the task afterwards does not stop it.
        for ($i = 0; $i -lt 20; $i++) {
            $state = Get-UnelevatedTaskState -TaskName $taskName
            if ($state.Running -or $state.Finished) { break }
            Start-Sleep -Milliseconds 250
        }
    }
    catch {
        Remove-UnelevatedTask -TaskName $taskName
        throw
    }
    if (-not $KeepTask) { Remove-UnelevatedTask -TaskName $taskName }
    $taskName
}

# Running: the process is still open. Finished: it ran and exited with ExitCode.
function Get-UnelevatedTaskState {
    param([Parameter(Mandatory)][string]$TaskName)
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\GpuVM\' -ErrorAction SilentlyContinue
    if (-not $task) { return [pscustomobject]@{ Running = $false; Finished = $true; ExitCode = -1 } }
    $info = $task | Get-ScheduledTaskInfo
    # 0x41301: running; 0x41303: has not run yet.
    $finished = $task.State -ne 'Running' -and $info.LastTaskResult -notin 0x41301, 0x41303
    [pscustomobject]@{ Running = $task.State -eq 'Running'; Finished = $finished; ExitCode = [int64]$info.LastTaskResult }
}

function Remove-UnelevatedTask {
    param([Parameter(Mandatory)][string]$TaskName)
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\GpuVM\' -Confirm:$false -ErrorAction SilentlyContinue
}

# Picks the pairing request that Moonlight on this host started. Another device on the guest's network
# could ask to pair at the same time; its request must not get the PIN. Sunshine reports where the request
# came from (address), which must be the host's IP on the VM's network; without an address, the name must match.
function Select-MoonlightPairingRequest {
    param(
        [object[]]$Pending,
        [Parameter(Mandatory)][string]$HostAddress,
        [Parameter(Mandatory)][string]$ClientName
    )
    $matched = @($Pending | Where-Object { $_ } | Where-Object {
        $address = if ($_.PSObject.Properties['address']) { [string]$_.address } else { '' }
        if ($address) { ($address -replace '^::ffff:', '' -replace ':\d+$', '') -eq $HostAddress }
        else { $_.PSObject.Properties['name'] -and [string]$_.name -eq $ClientName }
    })
    if ($matched.Count -gt 1) { throw 'Hay varias solicitudes de emparejamiento desde este equipo; vuelve a intentarlo.' }
    if ($matched.Count) { $matched[0] }
}

# Moonlight starts pairing with a PIN; the PIN is handed to Sunshine through its API, without opening the web UI.
function Register-MoonlightPairing {
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$MoonlightPath,
        [Parameter(Mandatory)][string]$ClientName,
        # The host's IP on the VM's network: the pairing request must come from it.
        [Parameter(Mandatory)][string]$HostAddress,
        [int]$TimeoutSec = 60
    )
    $pin = '{0:D4}' -f [Security.Cryptography.RandomNumberGenerator]::GetInt32(0, 10000)
    Write-Step "Emparejando Moonlight con Sunshine en $Address"
    $task = Start-UnelevatedProcess -FilePath $MoonlightPath -ArgumentList 'pair', $Address, '--pin', $pin -KeepTask
    try {
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        $submitted = $false
        while (-not $submitted -and (Get-Date) -lt $deadline -and -not (Get-UnelevatedTaskState -TaskName $task).Finished) {
            $pending = @((Invoke-SunshineApi -Address $Address -Credential $Credential -Path '/api/pin').pairings)
            $request = Select-MoonlightPairingRequest -Pending $pending -HostAddress $HostAddress -ClientName $ClientName
            if ($request) {
                $result = Invoke-SunshineApi -Address $Address -Credential $Credential -Method POST -Path '/api/pin' `
                    -Body @{ pairing_id = [string]$request.id; pin = $pin; name = $ClientName }
                if ($result.status -eq $false) { throw 'Sunshine rechazó el PIN de emparejamiento.' }
                $submitted = $true
            }
            else { Start-Sleep -Seconds 1 }
        }
        if (-not $submitted) { throw 'Moonlight no pidió emparejarse a tiempo.' }

        # Moonlight is not a child of this process: its exit code is the task's last result.
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while (-not ($state = Get-UnelevatedTaskState -TaskName $task).Finished) {
            if ((Get-Date) -gt $deadline) { throw 'Moonlight no terminó el emparejamiento.' }
            Start-Sleep -Seconds 1
        }
        if ($state.ExitCode -ne 0) { throw "Moonlight terminó el emparejamiento con código $($state.ExitCode)." }
        if (-not (Test-SunshineClientPaired -Address $Address -Credential $Credential -ClientName $ClientName)) {
            throw 'Sunshine no registró el emparejamiento de Moonlight.'
        }
    }
    finally {
        Remove-UnelevatedTask -TaskName $task
    }
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
    # Alt+F4, Alt+Tab and the Windows key go to the VM instead of closing or leaving Moonlight on this PC
    # (Ctrl+Alt+Shift+Q still quits the stream).
    # VMs created before this option existed get it too.
    $keys = if ($Client.Contains('captureSystemKeys')) { $Client['captureSystemKeys'] } else { 'fullscreen' }
    if ($keys -in 'never', 'fullscreen', 'always') { $arguments += '--capture-system-keys', $keys }
    $arguments
}
