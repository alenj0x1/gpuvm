# Apps installed inside the guest (Steam, Epic, Discord...). The catalog lives in apps/catalog.json; the guest
# downloads each installer from its publisher and runs it only if Windows says it is signed by the expected company.

function Get-AppCatalog { (Read-JsonFile (Get-RepoPath 'apps\catalog.json'))['apps'] }
function Get-AppCategory { (Read-JsonFile (Get-RepoPath 'apps\catalog.json'))['categories'] }

# Runs a program as the user signed in to the guest, unelevated, through a one-shot scheduled task (installers that
# refuse administrator rights, and uninstallers of per-user apps). It goes to the guest as text: a script block
# can't be passed to Invoke-Command as data.
$script:GuestRunAsUser = @'
param([string]$File, [string[]]$Arguments)
$user = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $user) { return @{ finished = $false; error = 'no hay una sesión iniciada en la VM' } }
$task = "GpuVM-App-$([guid]::NewGuid().ToString('n'))"
$action = if ($Arguments) { New-ScheduledTaskAction -Execute $File -Argument ($Arguments -join ' ') } else { New-ScheduledTaskAction -Execute $File }
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Force | Out-Null
try {
    Start-ScheduledTask -TaskName $task
    # 0x41301: running; 0x41303: has not run yet.
    $code = 0x41303
    for ($i = 0; $i -lt 300; $i++) {
        Start-Sleep -Seconds 2
        $code = (Get-ScheduledTaskInfo -TaskName $task).LastTaskResult
        if ($code -notin 0x41301, 0x41303) { break }
    }
}
finally { Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue }
@{ finished = $code -notin 0x41301, 0x41303; code = $code }
'@

# The places that say an app is installed ("installed" in the catalog, with ${VARIABLE}s), by app id.
function Get-AppInstalledPlace {
    $places = [ordered]@{}
    $catalog = Get-AppCatalog
    foreach ($id in $catalog.Keys) { $places[$id] = @($catalog[$id]['installed']) }
    $places
}

# Which catalog apps are installed in the running guest: the ids whose "installed" path exists.
function Get-GuestInstalledApp {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    $places = Get-AppInstalledPlace
    $found = Invoke-Guest -Name $Name -Credential $Credential -ArgumentList (, $places) -ScriptBlock {
        param($places)
        $expand = { param($path) [regex]::Replace($path, '\$\{([^}]+)\}', { param($m) [Environment]::GetEnvironmentVariable($m.Groups[1].Value) }) }
        foreach ($id in @($places.Keys)) {
            if (@($places[$id]) | Where-Object { Test-Path -LiteralPath (& $expand $_) }) { [string]$id }
        }
    }
    # Only ids GpuVM knows come back from the guest.
    @($found | ForEach-Object { [string]$_ } | Where-Object { $places.Contains($_) })
}

# Remembers in the VM's state what is installed, so the app knows it while the VM is off.
function Update-InstalledAppState {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Installed = @(),
        [string[]]$Removed = @(),
        # The whole list, from a check of the guest.
        [switch]$Replace
    )
    $state = Get-GpuVMState -Name $Name
    $current = @(if ($state.Contains('installedApps')) { $state['installedApps'] | Where-Object { $_ } })
    $next = if ($Replace) { @($Installed) } else { @(@($current) + @($Installed) | Where-Object { $_ -notin $Removed }) }
    $state['installedApps'] = @($next | Select-Object -Unique)
    Save-GpuVMState $state
}

# Powers the VM on if needed and waits for Windows, for installing or uninstalling apps. Returns the guest credential.
function Start-GuestForApp {
    param([Parameter(Mandatory)][string]$Name)
    $state = Get-GpuVMState -Name $Name
    $guest = Get-GpuVMGuestCredential -State $state
    if (-not $guest) { throw 'Guarda la contraseña de Windows de la VM para que GpuVM pueda instalar apps.' }
    $vm = Get-VM -Name $Name
    if ($vm.State -eq 'Off') {
        Assert-VMCanStart -Name $Name
        Write-Step 'Encendiendo'
        Start-VM -Name $Name
    }
    Wait-GuestReady -Name $Name -Credential $guest
    $guest
}

# Installs the apps that are missing, from inside the running guest. Returns one result per app.
function Install-GuestApp {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string[]]$App
    )
    $catalog = Get-AppCatalog
    foreach ($id in $App) {
        $entry = $catalog[$id]
        if (-not $entry) { throw "No existe la app '$id' en el catálogo." }
        if (-not $entry['signer'] -and -not $entry['sha256']) { throw "La app '$id' no tiene firmante ni hash: no se puede verificar." }
        Write-Step "Instalando $($entry['name'])"
        $result = Invoke-Guest -Name $Name -Credential $Credential -ArgumentList $entry, $script:GuestRunAsUser -ScriptBlock {
            param($entry, $runAsUser)
            $ErrorActionPreference = 'Stop'
            $expand = { param($path) [regex]::Replace($path, '\$\{([^}]+)\}', { param($m) [Environment]::GetEnvironmentVariable($m.Groups[1].Value) }) }
            # "installed" may list several places (some installers go per-machine or per-user depending on context).
            $places = @($entry['installed'] | ForEach-Object { & $expand $_ })
            $isInstalled = { [bool]($places | Where-Object { Test-Path -LiteralPath $_ }) }
            if (& $isInstalled) { return @{ status = 'present' } }
            $dir = Join-Path $env:TEMP 'GpuVM-apps'
            New-Item -ItemType Directory -Force $dir | Out-Null
            $file = Join-Path $dir $entry['file']
            Invoke-WebRequest -Uri $entry['url'] -OutFile $file -UseBasicParsing
            # The user's own unelevated programs can write to TEMP: the file stays open (others can only read it) from the
            # checks until the installer has run, so it can't be swapped in between.
            $lock = [IO.File]::Open($file, 'Open', 'Read', 'Read')
            try {
                # A pinned version also carries its hash: the file must be exactly that release.
                if ($entry['sha256'] -and (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry['sha256']) {
                    return @{ status = 'unsigned'; detail = 'el archivo no coincide con la versión verificada' }
                }
                # Without a signer (the publisher does not sign, as 7-Zip) the pinned hash above is the only check.
                if ($entry['signer']) {
                    $signature = Get-AuthenticodeSignature -LiteralPath $file
                    $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
                    # The organization (O=) must be exactly the publisher's legal name, not just start with it.
                    $signer = [regex]::Escape($entry['signer'])
                    if ($signature.Status -ne 'Valid' -or $subject -notmatch "(^|,\s*)O=`"?$signer`"?(,|$)") {
                        return @{ status = 'unsigned'; detail = "$($signature.Status) $subject" }
                    }
                }
                if ($entry['asUser']) {
                    # Installers that refuse administrator rights (Spotify) run as the signed-in user, unelevated.
                    $run = & ([scriptblock]::Create($runAsUser)) $file @($entry['args'])
                    if ($run['error']) { return @{ status = 'failed'; detail = $run['error'] } }
                    $finished = $run['finished']
                    $exitCode = $run['code']
                }
                else {
                    $process = if ($file.EndsWith('.msi')) {
                        Start-Process msiexec.exe -ArgumentList (@('/i', "`"$file`"") + $entry['args']) -PassThru
                    }
                    else { Start-Process -FilePath $file -ArgumentList $entry['args'] -PassThru }
                    # Only the installer itself is waited for (-Wait would also wait for what it leaves running, such as
                    # Discord or Chrome's updater, and never return), with a limit.
                    $finished = $process.WaitForExit(600000)
                    $exitCode = $process.ExitCode
                }
                if (-not $finished) { return @{ status = 'failed'; detail = 'el instalador no terminó en 10 minutos' } }
                # Some installers (Discord, Chrome) hand off to a background process; give them a moment.
                for ($i = 0; $i -lt 60 -and -not (& $isInstalled); $i++) { Start-Sleep -Seconds 2 }
                @{ status = if (& $isInstalled) { 'installed' } else { 'failed' }; detail = "código $exitCode" }
            }
            finally {
                $lock.Dispose()
                Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            }
        }
        # Only primitive values from the guest are used.
        $status = [string]$result['status']
        $detail = ([string]$result['detail'])
        if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 200) }
        switch ($status) {
            'present' { Write-Step "$($entry['name']) ya estaba instalado" }
            'installed' { Write-Step "$($entry['name']) instalado" }
            'unsigned' { Write-Warning "No se instaló $($entry['name']): el instalador no está firmado por $($entry['signer']) ($detail)." }
            default { Write-Warning "La instalación de $($entry['name']) no terminó bien ($detail)." }
        }
        if ($status -in 'installed', 'present') { Update-InstalledAppState -Name $Name -Installed $id }
        [ordered]@{ app = $id; name = $entry['name']; status = $status }
    }
}

# Uninstalls apps from inside the running guest with the uninstaller the app registered in Windows (Apps y
# características). Returns one result per app: uninstalled, absent or failed.
function Uninstall-GuestApp {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string[]]$App
    )
    $catalog = Get-AppCatalog
    foreach ($id in $App) {
        $entry = $catalog[$id]
        if (-not $entry) { throw "No existe la app '$id' en el catálogo." }
        if (-not $entry['uninstall']) { throw "La app '$id' no sabe desinstalarse." }
        Write-Step $(if ($entry['uninstall']['interactive']) { "Termina de desinstalar $($entry['name']) en la ventana de la VM" } else { "Desinstalando $($entry['name'])" })
        $result = Invoke-Guest -Name $Name -Credential $Credential -ArgumentList $entry, $script:GuestRunAsUser -ScriptBlock {
            param($entry, $runAsUser)
            $ErrorActionPreference = 'Stop'
            $expand = { param($path) [regex]::Replace($path, '\$\{([^}]+)\}', { param($m) [Environment]::GetEnvironmentVariable($m.Groups[1].Value) }) }
            $places = @($entry['installed'] | ForEach-Object { & $expand $_ })
            $isInstalled = { [bool]($places | Where-Object { Test-Path -LiteralPath $_ }) }
            if (-not (& $isInstalled)) { return @{ status = 'absent' } }

            # The app's entry in Windows' list of programs: per machine (64 and 32 bit) or per user (the session's
            # and those of users with a loaded profile, such as the one signed in).
            $match = $entry['uninstall']['match']
            $keys = @(
                @{ path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; machine = $true }
                @{ path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; machine = $true }
                @{ path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'; machine = $false }
                @{ path = 'Registry::HKEY_USERS\*\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'; machine = $false }
            )
            $found = foreach ($key in $keys) {
                Get-ItemProperty -Path $key.path -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -match $match -and ($_.UninstallString -or $_.QuietUninstallString) } |
                    ForEach-Object { @{ item = $_; machine = $key.machine } }
            }
            # A bundle's own parts (SystemComponent = 1) are hidden from the list; the visible entry removes them all.
            $pick = @($found | Sort-Object { [int]($_.item.SystemComponent -eq 1) }) | Select-Object -First 1
            if (-not $pick) { return @{ status = 'failed'; detail = 'Windows no tiene registrado su desinstalador' } }
            $item = $pick.item

            # Splits a command line into the program and its arguments.
            $split = {
                param([string]$line)
                $line = $line.Trim()
                if ($line -match '^"([^"]+)"\s*(.*)$') { return @($Matches[1], $Matches[2]) }
                if ($line -match '^(.+?\.exe)\s*(.*)$') { return @($Matches[1], $Matches[2]) }
                @($line, '')
            }
            $quiet = [string]$item.QuietUninstallString
            $line = [string]$item.UninstallString
            if ($quiet) {
                # The publisher's own silent uninstall.
                $file, $arguments = & $split $quiet
            }
            elseif ($line -match '(?i)msiexec' -and ($line + ' ' + $item.PSChildName) -match '(\{[0-9A-Fa-f-]{36}\})') {
                $file = Join-Path $env:SystemRoot 'System32\msiexec.exe'
                $arguments = "/x $($Matches[1]) /qn /norestart"
            }
            else {
                $file, $arguments = & $split $line
                $arguments = (@($arguments) + @($entry['uninstall']['args']) | Where-Object { $_ }) -join ' '
            }
            if (-not (Test-Path -LiteralPath $file)) { return @{ status = 'failed'; detail = "no está su desinstalador ($file)" } }

            # A per-user entry can be written by the user's own programs: it runs as that user, never elevated. An
            # uninstaller without a silent mode opens on the signed-in user's desktop, to finish it there.
            if ($entry['asUser'] -or -not $pick.machine -or $entry['uninstall']['interactive']) {
                $run = & ([scriptblock]::Create($runAsUser)) $file @($arguments)
                if ($run['error']) { return @{ status = 'failed'; detail = $run['error'] } }
                $finished = $run['finished']
                $exitCode = $run['code']
            }
            else {
                $process = if ($arguments) { Start-Process -FilePath $file -ArgumentList $arguments -PassThru } else { Start-Process -FilePath $file -PassThru }
                $finished = $process.WaitForExit(600000)
                $exitCode = $process.ExitCode
            }
            if (-not $finished) { return @{ status = 'failed'; detail = 'el desinstalador no terminó en 10 minutos' } }
            # NSIS and Inno uninstallers copy themselves to TEMP and return at once; the files go a moment later.
            for ($i = 0; $i -lt 90 -and (& $isInstalled); $i++) { Start-Sleep -Seconds 2 }
            @{ status = if (& $isInstalled) { 'failed' } else { 'uninstalled' }; detail = "código $exitCode" }
        }
        $status = [string]$result['status']
        $detail = ([string]$result['detail'])
        if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 200) }
        switch ($status) {
            'absent' { Write-Step "$($entry['name']) no estaba instalado" }
            'uninstalled' { Write-Step "$($entry['name']) desinstalado" }
            default { Write-Warning "No se pudo desinstalar $($entry['name']) ($detail)." }
        }
        if ($status -in 'uninstalled', 'absent') { Update-InstalledAppState -Name $Name -Removed $id }
        [ordered]@{ app = $id; name = $entry['name']; status = $status }
    }
}

# What GpuVM leaves pending for the next time the guest is up: growing C: after a disk resize and apps
# chosen when creating the VM. Errors only warn; they must not stop the VM from opening.
function Invoke-GuestPendingWork {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        # Size of the system disk now: C: is only grown when it differs from the last time it was (lab 019: checking
        # it took ~10 s of every open).
        [string]$DiskBytes
    )
    $state = Get-GpuVMState -Name $Name
    if (-not $DiskBytes -or -not $state.Contains('diskExpandedBytes') -or [string]$state['diskExpandedBytes'] -ne $DiskBytes) {
        try {
            Expand-GuestSystemDisk -Name $Name -Credential $Credential
            if ($DiskBytes) {
                $state = Get-GpuVMState -Name $Name
                $state['diskExpandedBytes'] = $DiskBytes
                Save-GpuVMState $state
            }
        }
        catch { Write-Warning "No se pudo ampliar el disco C: de la VM: $($_.Exception.Message)" }
    }

    # A copy of a template still has the template's computer name; it takes its own from the next restart.
    if ($state.Contains('pendingRename') -and $state['pendingRename']) {
        try {
            $computerName = ConvertTo-ComputerName $Name
            Invoke-Guest -Name $Name -Credential $Credential -ArgumentList $computerName -ScriptBlock {
                param($computerName)
                if ($env:COMPUTERNAME -ne $computerName) {
                    Rename-Computer -NewName $computerName -Force -WarningAction SilentlyContinue
                    # Automatic sign-in uses the computer name as the account's domain; with the old one it would fail.
                    Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultDomainName -Value $computerName
                }
            }
            $state['pendingRename'] = $false
            Save-GpuVMState $state
        }
        catch { Write-Warning "No se pudo cambiar el nombre del equipo de la VM: $($_.Exception.Message)" }
    }
    # Shared disks attached while the VM was off get their drive letter (and Steam library) now.
    foreach ($disk in @(Get-GpuVMSharedDisk | Where-Object { $_['vm'] -eq $Name })) {
        try { Initialize-GuestSharedDisk -VMName $Name -Credential $Credential -Disk (Read-SharedDisk -Name $disk['name']) | Out-Null }
        catch { Write-Warning "No se pudo preparar el disco '$($disk['name'])' en la VM: $($_.Exception.Message)" }
    }
    # Apps no longer in the catalog (it changed between versions) are dropped instead of failing every time.
    $known = @((Get-AppCatalog).Keys)
    $pending = @($(if ($state.Contains('pendingApps')) { $state['pendingApps'] }) | Where-Object { $_ -and $_ -in $known })
    if (-not $pending) { return }
    try {
        $results = @(Install-GuestApp -Name $Name -Credential $Credential -App $pending)
        $state = Get-GpuVMState -Name $Name
        $state['pendingApps'] = @($results | Where-Object { $_['status'] -notin 'installed', 'present' } | ForEach-Object { $_['app'] })
        Save-GpuVMState $state
    }
    catch { Write-Warning "No se pudieron instalar las apps: $($_.Exception.Message)" }
}
