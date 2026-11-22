# Never touch Microsoft Defender, Windows Update, SmartScreen, UAC or the firewall.

$GpuVMCleanupLevels = @('none', 'privacy', 'apps', 'minimal')
$GpuVMCleanupLevelNames = @{ none = 'Normal'; privacy = 'Privacy'; apps = 'No extra apps'; minimal = 'Minimal' }

$GpuVMCleanup = [ordered]@{
    'telemetry-minimum'    = @{
        Level       = 'privacy'
        Description = 'Diagnostic data at the lowest level the edition allows (on Pro, “Required”; on Enterprise and Education, off).'
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
        Description = 'No advertising ID or tailored experiences from your diagnostic data.'
        Registry    = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'; Name = 'DisabledByGroupPolicy'; Value = 1 }
            @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableTailoredExperiencesWithDiagnosticData'; Value = 1 }
        )
    }
    'activity-history'     = @{
        Level       = 'privacy'
        Description = 'No activity history and no activity sent to Microsoft.'
        Registry    = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'EnableActivityFeed'; Value = 0 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'PublishUserActivities'; Value = 0 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'UploadUserActivities'; Value = 0 }
        )
    }
    'suggestions'          = @{
        Level       = 'privacy'
        Description = 'No suggestions, tips, Spotlight or promoted apps that install themselves.'
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
        Description = 'Start''s search looks only on this PC, without Bing.'
        Registry    = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'DisableWebSearch'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'ConnectedSearchUseWeb'; Value = 0 }
            @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Value = 1 }
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'BingSearchEnabled'; Value = 0 }
        )
    }
    'copilot-recall'       = @{
        Level       = 'privacy'
        Description = 'No Copilot or Recall (the screenshots Windows 11 saves).'
        Registry    = @(
            @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'AllowRecallEnablement'; Value = 0 }
        )
    }
    'store-apps'           = @{
        Level       = 'apps'
        Description = 'Removes preinstalled apps that aren''t needed (news, weather, Solitaire, Clipchamp, personal Teams, new Outlook...), for new users too. They can be installed again from Microsoft Store.'
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
        Description = 'Removes OneDrive and keeps it from installing again.'
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
        Description = 'No widgets or “News and interests” on the taskbar.'
        Registry    = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests'; Value = 0 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds'; Name = 'EnableFeeds'; Value = 0 }
        )
    }
    'telemetry-services'   = @{
        Level       = 'minimal'
        Description = 'Turns off the services that send telemetry and error reports to Microsoft.'
        Services    = @(
            @{ Name = 'DiagTrack'; Default = 'Automatic' }
            @{ Name = 'dmwappushservice'; Default = 'Manual' }
            @{ Name = 'WerSvc'; Default = 'Manual' }
        )
    }
    'unneeded-services'    = @{
        Level       = 'minimal'
        Description = 'Turns off services a VM doesn''t use: maps, location, fax, demo mode and Windows Media sharing.'
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
        Description = 'Microsoft Store apps don''t run in the background.'
        Registry    = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; Name = 'LetAppsRunInBackground'; Value = 2 }
        )
    }
}

function Get-GpuVMCleanupItem {
    param([Parameter(Mandatory)][string]$Level)
    $rank = [array]::IndexOf($GpuVMCleanupLevels, $Level)
    if ($rank -lt 0) { throw "Unknown cleanup level: $Level" }
    foreach ($name in $GpuVMCleanup.Keys) {
        $item = $GpuVMCleanup[$name]
        [pscustomobject]@{ Name = $name; Item = $item; Included = [array]::IndexOf($GpuVMCleanupLevels, $item['Level']) -le $rank }
    }
}

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
                    Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq $package |
                        ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }
                    Get-AppxPackage -AllUsers -Name $package | ForEach-Object {
                        try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop; $removed++ } catch { }
                    }
                }
                $result.detail = "$removed apps removed"
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
