$script:SunshineWebPort = 47990

function New-RandomPassword {
    param([int]$Length = 24)
    $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'.ToCharArray()
    $bytes = [byte[]]::new($Length)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

function Get-SunshineForkFiles {
    $bundle = Get-RepoPath 'sunshine'
    foreach ($key in 'sunshine.exe', 'tools\sunshine_wgc_capture.exe') {
        $path = Join-Path $bundle $key
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "This GpuVM build is missing its Sunshine ($path). A developer's copy publishes it with gpuvm-sunshine\gpuvm\publish.ps1."
        }
        [pscustomobject]@{ Key = $key; Path = $path; Hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
    }
}

function Get-StreamingComponentNames {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Streaming)
    $names = @()
    if ($Streaming['provider'] -eq 'sunshine') { $names += 'sunshine' }
    if ($Streaming['virtualDisplay']) { $names += 'vdd' }
    if (Test-GpuVMAudio $Streaming) { $names += 'usbip' }
    if ($Streaming['virtualDisplay']) { $names += 'nefcon' }
    $names
}

function Test-GpuVMAudio {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Streaming)
    $Streaming['audio'] -in 'usb', 'vbcable'
}

# The Sunshine password travels in plain text to the guest (deleted after install) and is stored DPAPI-encrypted on the host.
function New-StreamingPayload {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $streaming = $Config['streaming']
    if (-not $streaming -or $streaming['provider'] -eq 'none') { return $null }

    $manifest = Get-ComponentManifest
    $files = @(foreach ($name in Get-StreamingComponentNames $streaming) {
        # The hash travels with the file so it can be re-verified right before copying it to the VM disk.
        @{ Source = Save-GpuVMComponent -Name $name -Manifest $manifest; Destination = 'streaming'; Sha256 = $manifest[$name]['sha256'] }
    })
    if ($streaming['provider'] -eq 'sunshine') {
        foreach ($file in Get-SunshineForkFiles) {
            $files += @{ Source = $file.Path; Destination = Join-Path 'streaming\fork' (Split-Path $file.Key -Parent); Sha256 = $file.Hash }
        }
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

# Guest values are untrusted: only a bounded string without control characters is kept.
function ConvertTo-GuestString {
    param($Value, [int]$MaxLength = 200)
    if ($Value -isnot [string] -and $Value -isnot [ValueType]) { return '' }
    $text = ([string]$Value) -replace '\p{C}', ' '
    if ($text.Length -gt $MaxLength) { $text = $text.Substring(0, $MaxLength) }
    $text
}

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

# The guest reports its own IP: only a host address of the host adapter's subnet on the VM's switch is accepted.
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

function Get-GpuVMHostNetwork {
    param([Parameter(Mandatory)][string]$Name)
    $switch = (Get-VMNetworkAdapter -VMName $Name | Select-Object -First 1).SwitchName
    if (-not $switch) { throw "The VM '$Name' isn't connected to any virtual switch." }
    $networks = @(Get-NetIPAddress -InterfaceAlias "vEthernet ($switch)" -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' } |
        ForEach-Object { [pscustomobject]@{ Address = $_.IPAddress; PrefixLength = [int]$_.PrefixLength } })
    if (-not $networks) { throw "The host has no IPv4 address on the switch '$switch' of the VM '$Name'; the IP the VM reports can't be checked." }
    $networks
}

function Get-GpuVMEndpoint {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutSec = 1200
    )
    $networks = Get-GpuVMHostNetwork -Name $Name
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
            throw ("The VM '{0}' reports the IP {1}, which isn't on the host's network with the VM ({2}). For safety it won't connect: check the VM's network adapter." -f
                $Name, (ConvertTo-GuestString ($reported -join ', ') -MaxLength 100), $subnets)
        }
        $vm = Get-VM -Name $Name
        $stopped = @{ Off = 'off'; Saved = 'saved'; Paused = 'paused' }
        if ($stopped.ContainsKey([string]$vm.State)) { throw "The VM '$Name' is $($stopped[[string]$vm.State]). Open it from GpuVM to turn it on." }
        if (((Get-Date) - $lastReport).TotalSeconds -ge 60) {
            $heartbeat = (Get-VMIntegrationService -VMName $Name | Where-Object { $_.Id -like '*84EAAE65-2F2E-45F5-9BB5-0E857DC8EB47*' }).PrimaryStatusDescription
            Write-Step ("Waiting for Windows on '{0}' ({1:N0} min; state {2}, CPU {3} %, heartbeat{4}). To see its screen: vmconnect.exe localhost {0}" -f
                $Name, ((Get-Date) - $started).TotalMinutes, $vm.State, $vm.CPUUsage, ($heartbeat ? " $heartbeat" : ': no data'))
            $lastReport = Get-Date
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    throw "The VM '$Name' didn't get an IP address in $([int]($TimeoutSec / 60)) min. See its screen with: vmconnect.exe localhost $Name"
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
        [string]$Message = 'Waiting for Sunshine'
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $announced = $false
    while ($true) {
        try { Invoke-SunshineApi -Address $Address -Credential $Credential -Path '/api/clients/list' | Out-Null; return }
        catch {
            if ((Get-Date) -gt $deadline) { throw "Sunshine isn't answering at ${Address}:$($script:SunshineWebPort). Check C:\GpuVM\setup.log inside the VM. Last error: $_" }
            if (-not $announced) { Write-Step $Message; $announced = $true }
            Start-Sleep -Seconds 3
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

# With the Hyper-V display active Sunshine captures it (no GPU) and streams black: pin the virtual display (EDID "MTT").
# Any per-session display change makes Sunshine re-test every encoder (first frame in 15-25 s instead of ~2 s).
function Set-SunshineVirtualDisplay {
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][pscredential]$Credential,
        [switch]$OnlyDisplay,
        [string]$Name,
        [pscredential]$GuestCredential
    )
    $lines = (Invoke-SunshineApi -Address $Address -Credential $Credential -Path '/api/logs') -split "`n"
    $vdd = ConvertFrom-SunshineDisplayLog -Lines $lines | Where-Object { $_.edid -and $_.edid.manufacturer_id -eq 'MTT' } | Select-Object -First 1
    if (-not $vdd) { Write-Warning 'Sunshine doesn''t see the virtual display; the picture may be black. Check C:\GpuVM\setup.log in the VM.'; return }

    $mode = if ($OnlyDisplay) { 'disabled' } else { 'ensure_only_display' }
    # nvenc_twopass: no quarter-resolution first pass, ~1.1 ms less from capture to packet. Other encoders ignore it.
    $settings = [ordered]@{ output_name = $vdd.device_id; dd_configuration_option = $mode; nvenc_twopass = 'disabled' }
    if (Update-SunshineConfig -Address $Address -Credential $Credential -Settings $settings -Name $Name -GuestCredential $GuestCredential) {
        Write-Step "Sunshine will capture the virtual display ($($vdd.display_name))"
    }
}

function Update-SunshineConfig {
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [string]$Name,
        [pscredential]$GuestCredential
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
    if ($Name -and $GuestCredential) {
        $null = Set-GuestCaptureMode -Name $Name -Credential $GuestCredential -Restart
    }
    else {
        # Sunshine drops the connection when restarting; the error from that call is expected.
        try { Invoke-SunshineApi -Address $Address -Credential $Credential -Method POST -Path '/api/restart' -Body @{} | Out-Null } catch { }
    }
    Start-Sleep -Seconds 5
    Wait-SunshineReady -Address $Address -Credential $Credential -TimeoutSec 120 -Message 'Sunshine is restarting with the new settings'
    $true
}

function Install-GuestAudio {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    $code = Get-Content -Raw -LiteralPath (Get-RepoPath 'guest\streaming.ps1')
    $server = Get-RepoPath 'guest\audio\UsbAudioServer.cs'
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $server).Hash
    $answer = Invoke-Guest -Name $Name -Credential $Credential -ArgumentList $code, $hash -ScriptBlock {
        param($code, $hash)
        . ([scriptblock]::Create($code))
        Repair-GpuVMAudio -SourceHash $hash
    }
    $answer = ConvertTo-GuestString (@($answer)[-1])
    $installed = $answer -eq 'install'
    if ($installed) {
        Write-Step 'Installing the VM''s audio'
        $installer = Save-GpuVMComponent -Name 'usbip'
        $session = New-PSSession -VMName $Name -Credential $Credential -ErrorAction Stop
        try {
            # Installed and compiled as administrator from an admin-only folder, not C:\GpuVM, where a guest user could swap them.
            $dir = New-GuestAdminFolder -Session $session -Prefix 'GpuVM-audio'
            try {
                Invoke-Command -Session $session -ErrorAction Stop -ArgumentList $dir { param($d) New-Item -ItemType Directory (Join-Path $d 'audio'), (Join-Path $d 'streaming') | Out-Null }
                Copy-Item -LiteralPath $installer -Destination "$dir\streaming" -ToSession $session -Force
                Copy-Item -LiteralPath $server -Destination "$dir\audio" -ToSession $session -Force
                $answer = Invoke-Command -Session $session -ErrorAction Stop -ArgumentList $code, $dir, $hash -ScriptBlock {
                    param($code, $dir, $hash)
                    . ([scriptblock]::Create($code))
                    if ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $dir 'audio\UsbAudioServer.cs')).Hash -ne $hash) { return 'error: the audio server''s source isn''t the one sent' }
                    Install-GpuVMAudio -Dir (Join-Path $dir 'streaming') -Root $dir
                }
                $answer = ConvertTo-GuestString (@($answer)[-1])
            }
            finally { Remove-GuestAdminFolder -Session $session -Path $dir }
        }
        finally { Remove-PSSession $session -ErrorAction SilentlyContinue }
    }
    if ($answer -ne 'ok') { throw "The VM's audio isn't ready: $($answer -replace '^error: ')" }
    $installed
}

function Install-GuestGamepad {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    $present = Invoke-Guest -Name $Name -Credential $Credential -ScriptBlock {
        [bool](Get-CimInstance Win32_SystemDriver -Filter "Name='ViGEmBus'" -ErrorAction SilentlyContinue)
    }
    if (@($present)[-1] -eq $true) { return $false }
    Write-Step 'Installing controller support in the VM'
    $installer = Save-GpuVMComponent -Name 'vigembus'
    $hash = (Get-ComponentManifest)['vigembus']['sha256']
    $session = New-PSSession -VMName $Name -Credential $Credential -ErrorAction Stop
    try {
        # Checked and run from an admin-only folder: in C:\GpuVM a guest user could swap the installer between check and run.
        $dir = New-GuestAdminFolder -Session $session -Prefix 'GpuVM-gamepad'
        try {
            Copy-Item -LiteralPath $installer -Destination $dir -ToSession $session -Force
            $answer = Invoke-Command -Session $session -ErrorAction Stop -ArgumentList "$dir\$(Split-Path $installer -Leaf)", $hash -ScriptBlock {
                param($path, $hash)
                if ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -ne $hash) { return 'error: the installer isn''t the expected one' }
                $signature = Get-AuthenticodeSignature -LiteralPath $path
                if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '^CN=Nefarius Software Solutions e\.U\.,') {
                    return 'error: the installer doesn''t have its author''s signature'
                }
                $p = Start-Process $path -ArgumentList '/quiet', '/norestart' -Wait -PassThru
                if ($p.ExitCode -notin 0, 3010) { return "error: the installer ended with code $($p.ExitCode)" }
                if (-not (Get-CimInstance Win32_SystemDriver -Filter "Name='ViGEmBus'")) { return 'error: the driver didn''t get installed' }
                'ok'
            }
        }
        finally { Remove-GuestAdminFolder -Session $session -Path $dir }
    }
    finally { Remove-PSSession $session -ErrorAction SilentlyContinue }
    $answer = ConvertTo-GuestString (@($answer)[-1])
    if ($answer -ne 'ok') { throw "Controller support isn't ready: $($answer -replace '^error: ')" }
    $true
}

function Start-GuestAudioCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    $code = Get-Content -Raw -LiteralPath (Get-RepoPath 'guest\streaming.ps1')
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Get-RepoPath 'guest\audio\UsbAudioServer.cs')).Hash
    $session = $null
    try {
        $session = New-PSSession -VMName $Name -Credential $Credential -ErrorAction Stop
        $job = Invoke-Command -Session $session -AsJob -ArgumentList $code, $hash -ScriptBlock {
            param($code, $hash)
            . ([scriptblock]::Create($code))
            Repair-GpuVMAudio -SourceHash $hash
        }
        [pscustomobject]@{ Session = $session; Job = $job }
    }
    catch {
        if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
        $null
    }
}

function Stop-GuestAudioCheck {
    param($Check, [int]$TimeoutSec = 60)
    if (-not $Check) { return }
    Wait-Job $Check.Job -Timeout $TimeoutSec | Out-Null
    Remove-Job $Check.Job -Force -ErrorAction SilentlyContinue
    Remove-PSSession $Check.Session -ErrorAction SilentlyContinue
}

# Windows localizes the speaker's name: found as a render endpoint ({0.0.0.…}) of the device we name.
function Get-GuestAudioSink {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    $sink = Invoke-Guest -Name $Name -Credential $Credential -ScriptBlock {
        Get-PnpDevice -Class AudioEndpoint -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -like 'SWD\MMDEVAPI\{0.0.0.*' -and $_.FriendlyName -like '*GpuVM Audio*' -and $_.Status -eq 'OK' } |
            Select-Object -First 1 -ExpandProperty FriendlyName
    }
    ConvertTo-GuestString (@($sink)[0]) -MaxLength 128
}

function Set-SunshineAudioSink {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    $sink = Get-GuestAudioSink -Name $Name -Credential $GuestCredential
    if (-not $sink) { Write-Warning 'The GpuVM Audio output wasn''t found in the VM; the picture will have no sound.'; return }
    if (Update-SunshineConfig -Address $Address -Credential $Credential -Settings ([ordered]@{ virtual_sink = $sink }) -Name $Name -GuestCredential $GuestCredential) {
        Write-Step "Sunshine captures the audio from $sink"
    }
}

$script:GuestSessions = @{}

function Invoke-Guest {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )
    if (Test-GpuVMHcsMachine -Name $Name) { return Invoke-HcsGuest -Name $Name -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList }
    $session = $script:GuestSessions[$Name]
    if ($session -and $session.State -eq 'Opened' -and $session.Availability -eq 'Available') {
        return Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    }
    Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
}

function Open-GuestSession {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][pscredential]$Credential)
    Close-GuestSession -Name $Name
    if (Test-GpuVMHcsMachine -Name $Name) { return }
    try { $script:GuestSessions[$Name] = New-PSSession -VMName $Name -Credential $Credential -ErrorAction Stop } catch { }
}

function Close-GuestSession {
    param([Parameter(Mandatory)][string]$Name)
    if ($script:GuestSessions[$Name]) { Remove-PSSession $script:GuestSessions[$Name] -ErrorAction SilentlyContinue }
    $script:GuestSessions.Remove($Name)
}

# Not an ISO date: ConvertFrom-Json would read that back as a DateTime, which never equals the text.
function Get-GuestBootTime {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][pscredential]$Credential)
    $boot = Invoke-Guest -Name $Name -Credential $Credential -ScriptBlock { [string](Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks }
    ConvertTo-GuestString (@($boot)[0]) -MaxLength 40
}

# PowerShell Direct before the heartbeat blocks ~30 s before failing. No heartbeat service counts as up.
function Test-GuestHeartbeat {
    param([Parameter(Mandatory)][string]$Name)
    $heartbeat = Get-VMIntegrationService -VMName $Name -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -like '*84EAAE65-2F2E-45F5-9BB5-0E857DC8EB47' } | Select-Object -First 1
    if (-not $heartbeat -or -not $heartbeat.Enabled) { return $true }
    "$($heartbeat.PrimaryOperationalStatus)" -eq 'Ok'
}

# Pairing before the first boot's restart cuts it off halfway: wait for setup.done.json and that restart.
function Wait-GuestReady {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        [int]$TimeoutSec = 1800,
        [string]$BootMessage = 'Waiting for Windows'
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $announced = $null
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-GuestHeartbeat -Name $Name)) {
            $message = $BootMessage
            if ($announced -ne $message) { Write-Step $message; $announced = $message }
            Start-Sleep -Seconds 1
            continue
        }
        # Only a single real $true counts (the guest could return any object that is "truthy").
        # @() outside the try: assigning a try block unrolls the array (one item becomes a scalar, none becomes $null).
        $answer = @(try {
            Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ScriptBlock {
                $path = 'C:\GpuVM\setup.done.json'
                # The first-time setup runs at the first sign-in of the machine's own account: with `agent` signing in, it never will.
                $console = [string](Get-CimInstance Win32_ComputerSystem).UserName
                if (-not (Test-Path $path) -and $console -like '*\agent') { return 'agent' }
                if (-not (Test-Path $path)) { return $false }
                $done = Get-Content -Raw $path | ConvertFrom-Json
                if ($done.PSObject.Properties['rebootPending'] -and -not $done.rebootPending) { return $true }
                (Get-CimInstance Win32_OperatingSystem).LastBootUpTime -gt (Get-Item $path).LastWriteTime
            }
        }
        catch { })
        $ready = $answer.Count -eq 1 -and $answer[0] -is [bool] -and $answer[0]
        if ($ready) { return }
        if ($answer.Count -eq 1 -and $answer[0] -eq 'agent') {
            Write-Warning 'GpuVM''s agent signs in to this machine, but its first-time setup never finished (the agent took over the sign-in before it did); carrying on without it.'
            return
        }
        $message = if ($answer.Count) { 'Windows is finishing its setup (first time only)' } else { $BootMessage }
        if ($announced -ne $message) { Write-Step $message; $announced = $message }
        Start-Sleep -Seconds 3
    }
    Write-Warning 'The VM''s first-time setup is taking longer than usual; carrying on anyway.'
}

function Wait-GuestSignIn {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        [int]$TimeoutSec = 900
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $announced = $null
    while ((Get-Date) -lt $deadline) {
        $status = try {
            Invoke-Guest -Name $Name -Credential $Credential -ScriptBlock {
                $user = (Get-CimInstance Win32_ComputerSystem).UserName
                $desktop = [bool](Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -gt 0 })
                # TiWorker is Windows' update installer at work.
                $updating = [bool](Get-Process TiWorker -ErrorAction SilentlyContinue)
                if ($user -and $desktop) { 'ready' } elseif ($updating) { 'updating' } else { 'signing-in' }
            }
        }
        catch { 'restarting' }
        $status = [string](@($status)[-1])
        if ($status -eq 'ready') { return $true }
        $message = switch ($status) {
            'updating' { 'Finishing updates' }
            'restarting' { 'Windows is restarting' }
            default { 'Signing in to Windows' }
        }
        if ($announced -ne $message) { Write-Step $message; $announced = $message }
        if ($status -eq 'restarting') {
            Close-GuestSession -Name $Name
            Start-Sleep -Seconds 3
            Wait-GuestReady -Name $Name -Credential $Credential -TimeoutSec ([math]::Max(30, ($deadline - (Get-Date)).TotalSeconds)) -BootMessage 'Windows is restarting'
            Open-GuestSession -Name $Name -Credential $Credential
            $announced = $null
            continue
        }
        Start-Sleep -Seconds 2
    }
    Write-Warning 'Windows didn''t sign in on the VM in time; the display and sound might not be ready.'
    $false
}

function Test-GuestUpdatePending {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][pscredential]$Credential)
    $pending = Invoke-Guest -Name $Name -Credential $Credential -ScriptBlock {
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    }
    @($pending)[-1] -eq $true
}

function Register-GuestUpdateBeforeShutdown {
    param([Parameter(Mandatory)][string]$Name)
    try {
        $state = Get-GpuVMState -Name $Name
        $guest = Get-GpuVMGuestCredential -State $state
        if (-not $guest -or (Get-VM -Name $Name).State -ne 'Running') { return $false }
        if (-not (Test-GuestUpdatePending -Name $Name -Credential $guest)) { return $false }
        $state['updatesPending'] = $true
        Save-GpuVMState $state
        $true
    }
    catch { $false }
}

function Set-GuestDisplayResolution {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$Resolution,
        [int]$Fps = 60
    )
    $width, $height = $Resolution.Split('x') | ForEach-Object { [int]$_ }
    $Fps = Resolve-GpuVMStreamFps $Fps
    if ($Fps -notin 30, 60, 90, 120, 144, 165, 244) {
        try { if (Add-GuestRefreshRate -Name $Name -Credential $Credential -Hz $Fps) { Write-Step "The VM's display at $Fps Hz, like your monitor" } }
        catch { Write-Warning "Couldn't add $Fps Hz to the VM's display: $($_.Exception.Message)" }
    }
    $code = Get-Content -Raw -LiteralPath (Get-RepoPath 'guest\set-resolution.ps1')
    $raw = Invoke-Guest -Name $Name -Credential $Credential -ArgumentList $code, $width, $height, $Fps, $script:GuestFolderCode -ScriptBlock {
        param($code, $width, $height, $fps, $folderCode)
        . ([scriptblock]::Create($folderCode))
        # The script goes in admin-only C:\GpuVM; the user's task answers through a folder the administrator only reads.
        $dir = 'C:\GpuVM'
        Protect-GpuVMGuestRoot -Path $dir
        $script = Join-Path $dir 'set-resolution.ps1'
        Remove-GpuVMItem -Path $script
        Set-Content -Path $script -Value $code -Encoding UTF8
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        if (-not $user) { return [pscustomobject]@{ ok = $false; error = 'No one is signed in on the screen.' } }
        $drop = New-GpuVMUserFolder -Root $dir -User $user
        try {
            $out = Join-Path $drop 'resolution.json'
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Width $width -Height $height -Refresh $fps -Out `"$out`""
            $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask -TaskName 'GpuVM-Resolution' -Action $action -Principal $principal -Force | Out-Null
            Start-ScheduledTask -TaskName 'GpuVM-Resolution'
            for ($i = 0; $i -lt 30 -and -not (Test-Path -LiteralPath $out -PathType Leaf); $i++) { Start-Sleep -Milliseconds 500 }
            Unregister-ScheduledTask -TaskName 'GpuVM-Resolution' -Confirm:$false
            if (Test-Path -LiteralPath $out -PathType Leaf) { Get-Content -Raw -LiteralPath $out | ConvertFrom-Json } else { [pscustomobject]@{ ok = $false; error = 'The task didn''t answer.' } }
        }
        finally { Remove-GpuVMFolder -Path $drop }
    }
    # The answer is rebuilt from primitives only: it comes from the guest and ends up in messages on the host.
    $raw = @($raw)[0]
    $field = { param($key) if ($null -ne $raw -and $raw.PSObject.Properties[$key]) { $raw.$key } }
    $ok = & $field 'ok'
    $changed = & $field 'changed'
    $result = [pscustomobject]@{
        ok      = $ok -is [bool] -and $ok
        applied = ConvertTo-GuestString (& $field 'applied') -MaxLength 40
        error   = ConvertTo-GuestString (& $field 'error')
        # Older guest scripts don't say; then it counts as changed (the safe side: Sunshine is restarted).
        changed = $changed -isnot [bool] -or $changed
    }
    if ($null -ne $raw -and $raw.PSObject.Properties['available']) {
        $result | Add-Member NoteProperty available (ConvertTo-GuestString $raw.available -MaxLength 400)
    }
    $result
}

# If the Hyper-V console or Remote Desktop took the session, Sunshine sees an empty screen: tscon returns it, as SYSTEM.
function Repair-GuestConsoleSession {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    $status = Invoke-Guest -Name $Name -Credential $Credential -ScriptBlock {
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

function Get-GpuVMViewerPath {
    $path = Join-Path $script:RepoRoot 'viewer\GpuVMViewer.exe'
    if (Test-Path -LiteralPath $path -PathType Leaf) { $path }
}

function Get-GpuVMViewerClientName { "$($env:COMPUTERNAME) GpuVM" }

# Moonlight talks to a server the guest controls, so it never runs elevated: a one-shot task at Limited run level.
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
    # The console user: another administrator account GpuVM was elevated with has no desktop session.
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

# Another device on the guest's network could ask to pair at the same time: only the host's request gets the PIN.
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
    if ($matched.Count -gt 1) { throw 'There are several pairing requests from this PC; try again.' }
    if ($matched.Count) { $matched[0] }
}

function Register-MoonlightPairing {
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$MoonlightPath,
        [Parameter(Mandatory)][string]$ClientName,
        [Parameter(Mandatory)][string]$HostAddress,
        [int]$TimeoutSec = 60,
        [switch]$Quiet
    )
    $pin = '{0:D4}' -f [Security.Cryptography.RandomNumberGenerator]::GetInt32(0, 10000)
    Write-Step "Pairing with Sunshine at $Address"
    $pairArguments = @('pair', $Address, '--pin', $pin)
    if ($Quiet) { $pairArguments += '--gpuvm-quiet' }
    $task = Start-UnelevatedProcess -FilePath $MoonlightPath -ArgumentList $pairArguments -KeepTask
    try {
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        $submitted = $false
        while (-not $submitted -and (Get-Date) -lt $deadline -and -not (Get-UnelevatedTaskState -TaskName $task).Finished) {
            $pending = @((Invoke-SunshineApi -Address $Address -Credential $Credential -Path '/api/pin').pairings)
            $request = Select-MoonlightPairingRequest -Pending $pending -HostAddress $HostAddress -ClientName $ClientName
            if ($request) {
                $result = Invoke-SunshineApi -Address $Address -Credential $Credential -Method POST -Path '/api/pin' `
                    -Body @{ pairing_id = [string]$request.id; pin = $pin; name = $ClientName }
                if ($result.status -eq $false) { throw 'Sunshine rejected the pairing PIN.' }
                $submitted = $true
            }
            else { Start-Sleep -Seconds 1 }
        }
        if (-not $submitted) { throw 'The viewer didn''t ask to pair in time.' }

        # Moonlight is not a child of this process: its exit code is the task's last result.
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while (-not ($state = Get-UnelevatedTaskState -TaskName $task).Finished) {
            if ((Get-Date) -gt $deadline) { throw 'The viewer didn''t finish pairing.' }
            Start-Sleep -Seconds 1
        }
        if ($state.ExitCode -ne 0) { throw "The viewer ended pairing with code $($state.ExitCode)." }
        if (-not (Test-SunshineClientPaired -Address $Address -Credential $Credential -ClientName $ClientName)) {
            throw 'Sunshine didn''t record the viewer''s pairing.'
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
    if ($Client['app'] -notmatch '^[\w .-]{1,60}$') { throw "Invalid Moonlight app name: $($Client['app'])" }
    $arguments = @('stream', $Address, "`"$($Client['app'])`"")
    if ($Client['resolution']) { $arguments += '--resolution', $Client['resolution'] }
    if ($Client.Contains('fps') -and $null -ne $Client['fps']) { $arguments += '--fps', [string](Resolve-GpuVMStreamFps $Client['fps']) }
    if ($Client['bitrateKbps']) { $arguments += '--bitrate', [string]$Client['bitrateKbps'] }
    if ($Client['codec'] -and $Client['codec'] -ne 'auto') { $arguments += '--video-codec', $Client['codec'] }
    $toggles = [ordered]@{ vsync = 'vsync'; framePacing = 'frame-pacing'; performanceOverlay = 'performance-overlay' }
    foreach ($key in $toggles.Keys) {
        if ($Client.Contains($key) -and $null -ne $Client[$key]) {
            $arguments += if ($Client[$key]) { "--$($toggles[$key])" } else { "--no-$($toggles[$key])" }
        }
    }
    if ($Client.Contains('mouse') -and $Client['mouse'] -in 'capture', 'absolute') {
        $arguments += if ($Client['mouse'] -eq 'absolute') { '--absolute-mouse' } else { '--no-absolute-mouse' }
    }
    if ($Client.Contains('displayMode') -and $Client['displayMode'] -in 'fullscreen', 'windowed', 'borderless') {
        $arguments += '--display-mode', $Client['displayMode']
    }
    $keys = if ($Client.Contains('captureSystemKeys')) { $Client['captureSystemKeys'] } else { 'fullscreen' }
    if ($keys -in 'never', 'fullscreen', 'always') { $arguments += '--capture-system-keys', $keys }
    $arguments
}
