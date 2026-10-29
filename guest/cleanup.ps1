# Windows cleanup levels: privacy, apps and minimal. Each level includes the ones before it.
# Every item is data (registry values, services, Store packages) applied by one engine, so it can be undone
# by lowering the level; removed Store apps are the exception (they come back from Microsoft Store).
# Nothing here touches Microsoft Defender, Windows Update, SmartScreen, UAC or the firewall: a cleaner
# Windows must never be a less secure one.
# Runs on Windows PowerShell 5.1 inside the VM, as the VM's user with administrator rights.

$GpuVMCleanupLevels = @('none', 'privacy', 'apps', 'minimal')
$GpuVMCleanupLevelNames = @{ none = 'Normal'; privacy = 'Privacidad'; apps = 'Sin apps de más'; minimal = 'Mínimo' }

$GpuVMCleanup = [ordered]@{
    'telemetry-minimum'    = @{
        Level       = 'privacy'
        Description = 'Datos de diagnóstico al mínimo que permite la edición (en Pro, «Requerido»; en Enterprise y Education, apagados).'
        Registry    = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Value = 0 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'DoNotShowFeedbackNotifications'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'LimitDiagnosticLogCollection'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'DisableOneSettingsDownloads'; Value = 1 }
            @{ Path = 'HKCU:\Software\Microsoft\Siuf\Rules'; Name = 'NumberOfSIUFInPeriod'; Value = 0 }
        )
    }
    'advertising'          = @{
        Level       = 'privacy'
        Description = 'Sin identificador de publicidad ni experiencias personalizadas con tus datos de diagnóstico.'
        Registry    = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'; Name = 'DisabledByGroupPolicy'; Value = 1 }
            @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableTailoredExperiencesWithDiagnosticData'; Value = 1 }
        )
    }
    'activity-history'     = @{
        Level       = 'privacy'
        Description = 'Sin historial de actividad ni envío de actividad a Microsoft.'
        Registry    = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'EnableActivityFeed'; Value = 0 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'PublishUserActivities'; Value = 0 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'UploadUserActivities'; Value = 0 }
        )
    }
    'suggestions'          = @{
        Level       = 'privacy'
        Description = 'Sin sugerencias, consejos, Spotlight ni apps promocionadas que se instalan solas.'
        Registry    = @(
            foreach ($name in 'ContentDeliveryAllowed', 'OemPreInstalledAppsEnabled', 'PreInstalledAppsEnabled', 'SilentInstalledAppsEnabled',
                'SoftLandingEnabled', 'SystemPaneSuggestionsEnabled', 'RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled',
                'SubscribedContent-310093Enabled', 'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
                'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled') {
                @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = $name; Value = 0 }
            }
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; Name = 'ScoobeSystemSettingEnabled'; Value = 0 }
        )
    }
    'web-search'           = @{
        Level       = 'privacy'
        Description = 'La búsqueda de Inicio busca solo en el equipo, sin Bing.'
        Registry    = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'DisableWebSearch'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'ConnectedSearchUseWeb'; Value = 0 }
            @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Value = 1 }
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'BingSearchEnabled'; Value = 0 }
        )
    }
    'copilot-recall'       = @{
        Level       = 'privacy'
        Description = 'Sin Copilot ni Recall (las capturas de pantalla que guarda Windows 11).'
        Registry    = @(
            @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'AllowRecallEnablement'; Value = 0 }
        )
    }
    'store-apps'           = @{
        Level       = 'apps'
        Description = 'Quita apps preinstaladas que no hacen falta (noticias, clima, Solitario, Clipchamp, Teams personal, Outlook nuevo...), también para usuarios nuevos. Se pueden volver a instalar desde Microsoft Store.'
        # Kept on purpose: Microsoft Store, App Installer (winget), Windows Security, Xbox (Game Pass), Photos,
        # Calculator, Notepad, Paint, Terminal, Snipping Tool, Media Player and the frameworks apps depend on.
        Packages    = @(
            'Clipchamp.Clipchamp', 'Microsoft.549981C3F5F10', 'Microsoft.BingNews', 'Microsoft.BingSearch', 'Microsoft.BingWeather',
            'Microsoft.Copilot', 'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.Messaging', 'Microsoft.Microsoft3DViewer',
            'Microsoft.MicrosoftOfficeHub', 'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.MixedReality.Portal', 'Microsoft.MSPaint',
            'Microsoft.Office.OneNote', 'Microsoft.OneConnect', 'Microsoft.OutlookForWindows', 'Microsoft.People', 'Microsoft.PowerAutomateDesktop',
            'Microsoft.Print3D', 'Microsoft.SkypeApp', 'Microsoft.Todos', 'Microsoft.Wallet', 'Microsoft.Windows.DevHome',
            'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps', 'Microsoft.YourPhone', 'Microsoft.ZuneVideo',
            'microsoft.windowscommunicationsapps', 'MicrosoftCorporationII.MicrosoftFamily', 'MicrosoftCorporationII.QuickAssist',
            'MicrosoftTeams', 'MSTeams'
        )
    }
    'onedrive'             = @{
        Level       = 'apps'
        Description = 'Quita OneDrive y evita que se vuelva a instalar.'
        Registry    = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'; Name = 'DisableFileSyncNGSC'; Value = 1 }
        )
        Script      = {
            Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            $setups = @(
                "$env:SystemRoot\System32\OneDriveSetup.exe"
                "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
                Get-ChildItem "$env:LOCALAPPDATA\Microsoft\OneDrive\*\OneDriveSetup.exe" -ErrorAction SilentlyContinue | ForEach-Object FullName
            ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
            foreach ($setup in $setups) { Start-Process -FilePath $setup -ArgumentList '/uninstall' -Wait -WindowStyle Hidden }
            # New users get OneDrive from this Run entry of the default profile; without it, it never comes back.
            & reg.exe load 'HKU\GpuVMDefault' "$env:SystemDrive\Users\Default\NTUSER.DAT" 2>&1 | Out-Null
            & reg.exe delete 'HKU\GpuVMDefault\Software\Microsoft\Windows\CurrentVersion\Run' /v OneDriveSetup /f 2>&1 | Out-Null
            [gc]::Collect()
            & reg.exe unload 'HKU\GpuVMDefault' 2>&1 | Out-Null
        }
    }
    'widgets'              = @{
        Level       = 'apps'
        Description = 'Sin widgets ni «Noticias e intereses» en la barra de tareas.'
        Registry    = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests'; Value = 0 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds'; Name = 'EnableFeeds'; Value = 0 }
        )
    }
    'telemetry-services'   = @{
        Level       = 'minimal'
        Description = 'Apaga los servicios que envían telemetría y el informe de errores a Microsoft.'
        Services    = @(
            @{ Name = 'DiagTrack'; Default = 'Automatic' }
            @{ Name = 'dmwappushservice'; Default = 'Manual' }
            @{ Name = 'WerSvc'; Default = 'Manual' }
        )
    }
    'unneeded-services'    = @{
        Level       = 'minimal'
        Description = 'Apaga servicios que una VM no usa: mapas, ubicación, fax, modo demo y uso compartido de Windows Media.'
        Services    = @(
            @{ Name = 'MapsBroker'; Default = 'Automatic' }
            @{ Name = 'lfsvc'; Default = 'Manual' }
            @{ Name = 'Fax'; Default = 'Manual' }
            @{ Name = 'RetailDemo'; Default = 'Manual' }
            @{ Name = 'WMPNetworkSvc'; Default = 'Manual' }
        )
    }
    'background-apps'      = @{
        Level       = 'minimal'
        Description = 'Las apps de Microsoft Store no corren en segundo plano.'
        Registry    = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; Name = 'LetAppsRunInBackground'; Value = 2 }
        )
    }
}

function Get-GpuVMCleanupItem {
    param([Parameter(Mandatory)][string]$Level)
    $rank = [array]::IndexOf($GpuVMCleanupLevels, $Level)
    if ($rank -lt 0) { throw "Nivel de limpieza desconocido: $Level" }
    foreach ($name in $GpuVMCleanup.Keys) {
        $item = $GpuVMCleanup[$name]
        [pscustomobject]@{ Name = $name; Item = $item; Included = [array]::IndexOf($GpuVMCleanupLevels, $item['Level']) -le $rank }
    }
}

# Applies the items of the level and undoes those of higher levels. Returns what it did, item by item.
function Invoke-GpuVMCleanup {
    param([Parameter(Mandatory)][string]$Level)
    foreach ($entry in Get-GpuVMCleanupItem -Level $Level) {
        $item = $entry.Item
        $result = [ordered]@{ name = $entry.Name; applied = $entry.Included; ok = $true; detail = '' }
        # Registry and service cmdlets report failures as non-terminating errors: make them stop the item.
        $ErrorActionPreference = 'Stop'
        try {
            foreach ($value in @($item['Registry'])) {
                if (-not $value) { continue }
                if ($entry.Included) {
                    # Only the value is written; the key may hold other settings and is never replaced.
                    if (-not (Test-Path $value.Path)) { New-Item -Path $value.Path -Force | Out-Null }
                    Set-ItemProperty -Path $value.Path -Name $value.Name -Value $value.Value -Type DWord
                }
                elseif (Test-Path $value.Path) {
                    Remove-ItemProperty -Path $value.Path -Name $value.Name -ErrorAction SilentlyContinue
                }
            }
            foreach ($service in @($item['Services'])) {
                if (-not $service) { continue }
                if (-not (Get-Service -Name $service.Name -ErrorAction SilentlyContinue)) { continue }
                if ($entry.Included) {
                    Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
                    Set-Service -Name $service.Name -StartupType Disabled
                }
                else { Set-Service -Name $service.Name -StartupType $service.Default }
            }
            if ($entry.Included -and $item['Packages']) {
                $removed = 0
                foreach ($package in $item['Packages']) {
                    # Provisioned: so new users do not get it; installed: for the users that already have it.
                    Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq $package |
                        ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }
                    Get-AppxPackage -AllUsers -Name $package | ForEach-Object {
                        try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop; $removed++ } catch { }
                    }
                }
                $result.detail = "$removed apps quitadas"
            }
            if ($entry.Included -and $item['Script']) { & $item['Script'] }
        }
        catch {
            $result.ok = $false
            $result.detail = $_.Exception.Message
        }
        [pscustomobject]$result
    }
}
