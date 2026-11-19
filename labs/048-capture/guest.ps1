# Shared helpers for labs 048-050 (dot-source). The probe lives in C:\GpuVMLab048 in the guest (removed by
# Remove-GuestProbe). Probes run like the real agent would: a one-shot SYSTEM scheduled task (stand-in for the SYSTEM
# service) runs `agentprobe launch --wait -- <args>`, which starts the probe in the active console session with the
# signed-in user's token (WTSQueryUserToken + CreateProcessAsUser, winsta0\default).
#   -AsSystem : the probe itself runs as SYSTEM in session 0.
#   -Direct   : the probe runs inside the PowerShell Direct session (elevated admin, session 0).

$script:ProbeExe = Join-Path $PSScriptRoot 'agentprobe\target\release\agentprobe.exe'
$script:GuestDir = 'C:\GpuVMLab048'

function Install-GuestProbe {
    param([Parameter(Mandatory)]$Session)
    Invoke-Command -Session $Session -ArgumentList $script:GuestDir {
        param($dir)
        New-Item -ItemType Directory -Force "$dir\out" | Out-Null
        icacls "$dir\out" /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null   # Users may write results
    }
    Copy-Item $script:ProbeExe -ToSession $Session -Destination "$script:GuestDir\agentprobe.exe" -Force
}

function Remove-GuestProbe {
    param([Parameter(Mandatory)]$Session)
    Invoke-Command -Session $Session -ArgumentList $script:GuestDir {
        param($dir)
        Get-Process agentprobe -ErrorAction SilentlyContinue | Stop-Process -Force
        Get-ScheduledTask -TaskName 'GpuVMLab048-*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
        Start-Sleep -Milliseconds 300
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Starts a probe and returns its id at once (for watchers that run while the host does something).
function Start-GuestProbe {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ProbeArgs,
        [switch]$AsSystem,
        [string]$Exe,          # with launch: another program to start in the session instead of the probe
        [int]$TimeoutSec = 300
    )
    Invoke-Command -Session $Session -ArgumentList $script:GuestDir, $ProbeArgs, $AsSystem.IsPresent, $Exe, $TimeoutSec {
        param($dir, $pargs, $asSystem, $exeOther, $timeout)
        $probe = "$dir\agentprobe.exe"
        $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $out = "$dir\out\$id.json"
        $quoted = ($pargs | ForEach-Object { '"' + $_ + '"' }) -join ' '
        $argline = if ($exeOther) { "launch --exe `"$exeOther`" -- $quoted" }
            elseif ($asSystem) { "$quoted --out `"$out`"" }
            else { "launch --wait -- $quoted --out `"$out`"" }
        $cmd = "/c `"`"$probe`" $argline > `"$dir\out\$id-launch.json`"`""
        $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $cmd
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds $timeout)
        Register-ScheduledTask -TaskName "GpuVMLab048-$id" -Action $action -Principal $principal -Settings $settings | Out-Null
        Start-ScheduledTask -TaskName "GpuVMLab048-$id"
        $id
    }
}

function Receive-GuestProbe {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Id, [int]$TimeoutSec = 300)
    Invoke-Command -Session $Session -ArgumentList $script:GuestDir, $Id, $TimeoutSec {
        param($dir, $id, $timeout)
        $name = "GpuVMLab048-$id"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $timeout) {
            $st = (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue).State
            if ($st -ne 'Running') { break }
            Start-Sleep -Milliseconds 100
        }
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
        $out = "$dir\out\$id.json"
        [pscustomobject]@{
            result = if (Test-Path $out) { Get-Content $out -Raw } else { $null }
            launch = if (Test-Path "$dir\out\$id-launch.json") { Get-Content "$dir\out\$id-launch.json" -Raw } else { $null }
        }
        Remove-Item "$dir\out\$id*" -ErrorAction SilentlyContinue
    }
}

function Invoke-GuestProbe {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string[]]$ProbeArgs,
        [switch]$AsSystem,
        [switch]$Direct,
        [int]$TimeoutSec = 300
    )
    if ($Direct) {
        return Invoke-Command -Session $Session -ArgumentList $script:GuestDir, $ProbeArgs {
            param($dir, $pargs)
            [pscustomobject]@{ result = (& "$dir\agentprobe.exe" @pargs) -join "`n"; launch = $null }
        }
    }
    $id = Start-GuestProbe -Session $Session -ProbeArgs $ProbeArgs -AsSystem:$AsSystem -TimeoutSec $TimeoutSec
    Receive-GuestProbe -Session $Session -Id $id -TimeoutSec $TimeoutSec
}

# Opens a program in the signed-in user's session (as the user, medium integrity).
function Start-GuestApp {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Exe, [string[]]$AppArgs = @())
    $id = Start-GuestProbe -Session $Session -ProbeArgs $AppArgs -Exe $Exe
    Receive-GuestProbe -Session $Session -Id $id -TimeoutSec 30
}
