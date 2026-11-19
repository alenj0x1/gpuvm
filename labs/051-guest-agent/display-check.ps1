# Which display does the agent work on in the `agent` session? A disposable from agent-tpl (turned off = deleted at
# the end); the new gpuvm-agent.exe runs `diag` as the agent user (one-shot interactive task) and reports every
# attached display (GDI, physical pixels), the target one and a real WGC capture's size. One lab lock. Run elevated.
param([string]$Template = 'agent-tpl', [string]$Name = 'agent051-diag', [string]$Me = 'agent-guest')
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
& (Join-Path $repo 'labs\042-admin-dock\take-lock.ps1') -What "lab 051: display check on disposable $Name from $Template" -Me $Me
if ($LASTEXITCODE -ne 0) { throw 'no lock' }
try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # a normal copy (removed at the end): the installed build deleted a just-created disposable seconds later
    New-GpuVM -Name $Name -Template $Template -Start -Confirm:$false | Out-Null
    if ((Get-VM -Name $Name).State -ne 'Running') { Start-VM -Name $Name }
    "created + started in $([int]$sw.Elapsed.TotalSeconds) s, state $((Get-VM -Name $Name).State)"
    $gc = & (Get-Module GpuVM) { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $Name
    do {
        Start-Sleep -Seconds 2
        $u = try { Invoke-Command -VMName $Name -Credential $gc -ErrorAction Stop { (Get-CimInstance Win32_ComputerSystem).UserName } } catch { $null }
    } until (($u -like '*\agent') -or $sw.Elapsed.TotalMinutes -gt 8)
    "signed in as $u after $([int]$sw.Elapsed.TotalSeconds) s"
    Start-Sleep -Seconds 10   # let the display settle
    $s = New-PSSession -VMName $Name -Credential $gc
    Copy-Item (Join-Path $repo 'guest\agent\dist\gpuvm-agent.exe') -Destination 'C:\Users\Public\gpuvm-agent-diag.exe' -ToSession $s -Force
    Invoke-Command -Session $s {
        $wmi = Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name)=$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)" }
        "WMI: $($wmi -join '; ')"
        $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c C:\Users\Public\gpuvm-agent-diag.exe diag > C:\Users\Public\diag.json 2>&1'
        $p = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\agent" -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName Lab051Diag -Action $a -Principal $p -Force | Out-Null
        Start-ScheduledTask -TaskName Lab051Diag
        $t = 0; while (((Get-ScheduledTask -TaskName Lab051Diag).State -ne 'Ready' -or -not (Test-Path C:\Users\Public\diag.json)) -and $t -lt 100) { Start-Sleep -Milliseconds 200; $t++ }
        Unregister-ScheduledTask -TaskName Lab051Diag -Confirm:$false
        "diag: $(Get-Content C:\Users\Public\diag.json -Raw)"
    }
    Remove-PSSession $s
}
finally {
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
        Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue
        Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    "lock released $(Get-Date -Format HH:mm:ss); VM still there: $([bool](Get-VM -Name $Name -ErrorAction SilentlyContinue))"
}
