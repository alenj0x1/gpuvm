# Catalog of guest optimizations. Each profile picks which ones to apply in guest.optimizations.
# To add one: a new entry with a description and an idempotent block; then test it in a lab.
# Runs on Windows PowerShell 5.1 inside the VM.

$GpuVMOptimizations = [ordered]@{
    'power-plan-high'            = @{
        Description = 'Plan de energía "Alto rendimiento".'
        Apply       = { powercfg.exe /setactive SCHEME_MIN | Out-Null }
    }
    'power-plan-ultimate'        = @{
        Description = 'Plan "Máximo rendimiento" (Ultimate Performance); si no está disponible, Alto rendimiento.'
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
        Description = 'Sin suspensión, hibernación ni apagado de pantalla (cortan el streaming).'
        Apply       = {
            powercfg.exe /hibernate off | Out-Null
            powercfg.exe /change standby-timeout-ac 0 | Out-Null
            powercfg.exe /change monitor-timeout-ac 0 | Out-Null
        }
    }
    'game-mode'                  = @{
        Description = 'Modo de juego de Windows activado.'
        Apply       = {
            $key = 'HKCU:\Software\Microsoft\GameBar'
            if (-not (Test-Path $key)) { New-Item $key -Force | Out-Null }
            Set-ItemProperty $key -Name AutoGameModeEnabled -Value 1 -Type DWord
            Set-ItemProperty $key -Name AllowAutoGameMode -Value 1 -Type DWord
        }
    }
    'disable-sysmain'            = @{
        Description = 'Desactiva SysMain (Superfetch); en disco virtual solo agrega E/S.'
        Apply       = {
            Stop-Service SysMain -Force -ErrorAction SilentlyContinue
            Set-Service SysMain -StartupType Disabled
        }
    }
    'disable-search-indexing'    = @{
        Description = 'Desactiva el indexador de Windows Search.'
        Apply       = {
            Stop-Service WSearch -Force -ErrorAction SilentlyContinue
            Set-Service WSearch -StartupType Disabled
        }
    }
    'visual-effects-performance' = @{
        Description = 'Efectos visuales ajustados para rendimiento.'
        Apply       = {
            $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
            if (-not (Test-Path $key)) { New-Item $key -Force | Out-Null }
            Set-ItemProperty $key -Name VisualFXSetting -Value 2 -Type DWord
        }
    }
}
