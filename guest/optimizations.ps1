# Catalog of guest optimizations. Each profile picks which ones to apply in guest.optimizations.
# To add one: a new entry with a description and an idempotent block; then test it in a lab.
# Runs on Windows PowerShell 5.1 inside the VM.

$GpuVMOptimizations = [ordered]@{
    'power-plan-high'            = @{
        Description = '"High performance" power plan.'
        Apply       = { powercfg.exe /setactive SCHEME_MIN | Out-Null }
    }
    'power-plan-ultimate'        = @{
        Description = '"Ultimate Performance" plan; High performance if it isn''t available.'
        Apply       = {
            $ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
            $output = powercfg.exe /duplicatescheme $ultimate 2>&1 | Out-String
            if ($output -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
                powercfg.exe /setactive $Matches[1] | Out-Null
            }
            else {
                powercfg.exe /setactive SCHEME_MIN | Out-Null
            }
        }
    }
    'disable-sleep'              = @{
        Description = 'No sleep, hibernation or display turning off (they cut the stream).'
        Apply       = {
            powercfg.exe /hibernate off | Out-Null
            powercfg.exe /change standby-timeout-ac 0 | Out-Null
            powercfg.exe /change monitor-timeout-ac 0 | Out-Null
        }
    }
    'game-mode'                  = @{
        Description = 'Windows Game Mode on.'
        Apply       = {
            $key = 'HKCU:\Software\Microsoft\GameBar'
            if (-not (Test-Path $key)) { New-Item $key -Force | Out-Null }
            Set-ItemProperty $key -Name AutoGameModeEnabled -Value 1 -Type DWord
            Set-ItemProperty $key -Name AllowAutoGameMode -Value 1 -Type DWord
        }
    }
    'disable-sysmain'            = @{
        Description = 'Turns off SysMain (Superfetch); on a virtual disk it only adds I/O.'
        Apply       = {
            Stop-Service SysMain -Force -ErrorAction SilentlyContinue
            Set-Service SysMain -StartupType Disabled
        }
    }
    'disable-search-indexing'    = @{
        Description = 'Turns off the Windows Search indexer.'
        Apply       = {
            Stop-Service WSearch -Force -ErrorAction SilentlyContinue
            Set-Service WSearch -StartupType Disabled
        }
    }
    'block-gpu-driver-updates'   = @{
        Description = 'Windows Update doesn''t install drivers: an NVIDIA one over the driver copied from the host leaves the VM without a GPU.'
        Apply       = {
            $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
            if (-not (Test-Path $key)) { New-Item $key -Force | Out-Null }
            Set-ItemProperty $key -Name ExcludeWUDriversInQualityUpdate -Value 1 -Type DWord
            Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' -Name SearchOrderConfig -Value 0 -Type DWord
        }
    }
    'visual-effects-performance' = @{
        Description = 'Visual effects set for performance.'
        Apply       = {
            $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
            if (-not (Test-Path $key)) { New-Item $key -Force | Out-Null }
            Set-ItemProperty $key -Name VisualFXSetting -Value 2 -Type DWord
        }
    }
}
