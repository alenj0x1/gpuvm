# Apps installed inside the guest (Steam, Epic, Discord...). The catalog lives in apps/catalog.json; the guest
# downloads each installer from its publisher and runs it only if Windows says it is signed by the expected company.

function Get-AppCatalog { (Read-JsonFile (Get-RepoPath 'apps\catalog.json'))['apps'] }
function Get-AppCategory { (Read-JsonFile (Get-RepoPath 'apps\catalog.json'))['categories'] }

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
        $result = Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ArgumentList (, $entry) -ScriptBlock {
            param($entry)
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
                    # Installers that refuse administrator rights (Spotify) run as the signed-in user, unelevated,
                    # through a one-shot scheduled task in that user's session.
                    $user = (Get-CimInstance Win32_ComputerSystem).UserName
                    if (-not $user) { return @{ status = 'failed'; detail = 'no hay una sesión iniciada en la VM' } }
                    $task = "GpuVM-App-$([guid]::NewGuid().ToString('n'))"
                    $action = New-ScheduledTaskAction -Execute $file -Argument ($entry['args'] -join ' ')
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
                    $finished = $code -notin 0x41301, 0x41303
                    $exitCode = $code
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
        [ordered]@{ app = $id; name = $entry['name']; status = $status }
    }
}

# What GpuVM leaves pending for the next time the guest is up: growing C: after a disk resize and apps
# chosen when creating the VM. Errors only warn; they must not stop the VM from opening.
function Invoke-GuestPendingWork {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    try { Expand-GuestSystemDisk -Name $Name -Credential $Credential }
    catch { Write-Warning "No se pudo ampliar el disco C: de la VM: $($_.Exception.Message)" }

    $state = Get-GpuVMState -Name $Name
    # A copy of a template still has the template's computer name; it takes its own from the next restart.
    if ($state.Contains('pendingRename') -and $state['pendingRename']) {
        try {
            $computerName = ConvertTo-ComputerName $Name
            Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ArgumentList $computerName -ScriptBlock {
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
