# Apps installed inside the guest (Steam, Epic, Discord...). The catalog lives in apps/catalog.json; the guest
# downloads each installer from its publisher and runs it only if Windows says it is signed by the expected company.

function Get-AppCatalog { (Read-JsonFile (Get-RepoPath 'apps\catalog.json'))['apps'] }

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
            # A pinned version also carries its hash: the file must be exactly that release.
            if ($entry['sha256'] -and (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry['sha256']) {
                Remove-Item -LiteralPath $file -Force
                return @{ status = 'unsigned'; detail = 'el archivo no coincide con la versión verificada' }
            }
            $signature = Get-AuthenticodeSignature -LiteralPath $file
            $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
            # The organization (O=) must be exactly the publisher's legal name, not just start with it.
            $signer = [regex]::Escape($entry['signer'])
            if ($signature.Status -ne 'Valid' -or $subject -notmatch "(^|,\s*)O=`"?$signer`"?(,|$)") {
                Remove-Item -LiteralPath $file -Force
                return @{ status = 'unsigned'; detail = "$($signature.Status) $subject" }
            }
            $process = if ($file.EndsWith('.msi')) {
                Start-Process msiexec.exe -ArgumentList (@('/i', "`"$file`"") + $entry['args']) -PassThru
            }
            else { Start-Process -FilePath $file -ArgumentList $entry['args'] -PassThru }
            # Only the installer itself is waited for (-Wait would also wait for what it leaves running, such as
            # Discord or Chrome's updater, and never return), with a limit.
            $finished = $process.WaitForExit(600000)
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            if (-not $finished) { return @{ status = 'failed'; detail = 'el instalador no terminó en 10 minutos' } }
            # Some installers (Discord, Chrome) hand off to a background process; give them a moment.
            for ($i = 0; $i -lt 60 -and -not (& $isInstalled); $i++) { Start-Sleep -Seconds 2 }
            @{ status = if (& $isInstalled) { 'installed' } else { 'failed' }; detail = "código $($process.ExitCode)" }
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
