# Lab 055: on the agent copy, swaps Sunshine between the service (SYSTEM, ddx: what agent machines use today) and
# Sunshine started as the separate standard user gpuvm-stream inside `agent`'s session (wgc). -Mode user|service.
# -High starts it at high integrity. Prints who runs Sunshine afterwards. Run elevated.
param([string]$Name = 'agent055', [ValidateSet('user', 'service')][string]$Mode = 'user', [switch]$High)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
$m = Get-Module GpuVM
$state = & $m { param($n) Get-GpuVMState -Name $n } $Name
$cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
$s = New-PSSession -VMName $Name -Credential $cred
try {
    Invoke-Command -Session $s {
        $dir = 'C:\GpuVMLab055'
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory $dir | Out-Null
            # SYSTEM and administrators only: SYSTEM runs these scripts.
            icacls $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
        }
    }
    foreach ($f in 'StreamLauncher.cs', 'stage0.ps1', 'stage1.ps1') { Copy-Item (Join-Path $PSScriptRoot $f) -Destination 'C:\GpuVMLab055\' -ToSession $s -Force }
    Invoke-Command -Session $s -ArgumentList $Mode, $High.IsPresent {
        param($mode, $high)
        $ErrorActionPreference = 'Stop'
        $dir = 'C:\GpuVMLab055'
        $conf = 'C:\Program Files\Sunshine\config\sunshine.conf'
        $svc = Get-Service SunshineService
        function Set-Capture($value) {
            $lines = @(Get-Content $conf | Where-Object { $_ -notmatch '^\s*capture\s*=' })
            if ($value) { $lines += "capture = $value" }
            Set-Content $conf $lines -Encoding ASCII
        }
        function Stop-Sunshine {
            Stop-Service SunshineService -Force -ErrorAction SilentlyContinue
            Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep -Milliseconds 800
        }
        Stop-Sunshine
        if ($mode -eq 'service') {
            Set-Capture $null
            Set-Service SunshineService -StartupType Automatic
            Start-Service SunshineService
        }
        else {
            if (-not (Get-LocalUser -Name 'gpuvm-stream' -ErrorAction SilentlyContinue)) {
                $b = New-Object byte[] 24; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
                $pw = ConvertTo-SecureString ('Aa1!' + [Convert]::ToBase64String($b)) -AsPlainText -Force
                New-LocalUser -Name 'gpuvm-stream' -Password $pw -PasswordNeverExpires -AccountNeverExpires -UserMayNotChangePassword -Description 'GpuVM streaming (lab 055)' | Out-Null
                # Not on the sign-in screen.
                $ul = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
                New-Item $ul -Force | Out-Null; New-ItemProperty $ul -Name 'gpuvm-stream' -Value 0 -PropertyType DWord -Force | Out-Null
            }
            Add-Type -Path (Join-Path $dir 'StreamLauncher.cs')
            $sid = (Get-LocalUser 'gpuvm-stream').SID.Value
            # Batch logon only; never interactive, remote desktop or network.
            $rights = 'SeBatchLogonRight', 'SeDenyRemoteInteractiveLogonRight', 'SeDenyNetworkLogonRight'
            if (-not (Test-Path (Join-Path $dir 'interactive'))) { $rights += 'SeDenyInteractiveLogonRight' }
            foreach ($r in $rights) { [StreamLauncher]::AddRight($sid, $r) }
            # Lab only: the user owns Sunshine's config folder (the real design gives it its own folder).
            icacls 'C:\Program Files\Sunshine\config' /grant "*$($sid):(OI)(CI)M" | Out-Null
            icacls 'C:\Program Files\Sunshine\config\credentials' /grant "*$($sid):(OI)(CI)R" | Out-Null
            Set-Capture 'wgc'
            Set-Service SunshineService -StartupType Disabled
            if ($high) { New-Item (Join-Path $dir 'high') -Force | Out-Null } else { Remove-Item (Join-Path $dir 'high') -ErrorAction SilentlyContinue }
            Remove-Item (Join-Path $dir 'launch.log') -ErrorAction SilentlyContinue
            $task = 'GpuVMLab055'
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dir\stage0.ps1`""
            $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
            Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Force | Out-Null
            Start-ScheduledTask -TaskName $task
            $end = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $end -and -not ((Test-Path "$dir\launch.log") -and (Get-Content "$dir\launch.log" -Raw) -match 'sunshine pid|ERROR')) { Start-Sleep -Milliseconds 300 }
            Get-Content "$dir\launch.log"
        }
        Start-Sleep -Seconds 15
        foreach ($p in Get-CimInstance Win32_Process -Filter "Name = 'sunshine.exe'") {
            $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner
            "sunshine.exe pid $($p.ProcessId) session $($p.SessionId) owner $($o.Domain)\$($o.User)"
        }
        "capture line: $((Select-String -Path $conf -Pattern '^\s*capture\s*=').Line)"
        "sessions: $((quser 2>$null) -join ' | ')"
    }
}
finally { Remove-PSSession $s }
