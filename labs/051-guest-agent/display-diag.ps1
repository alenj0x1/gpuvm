# Diagnosis: a disposable from agent-tpl reported NO attached display for 60 s after its install's restart (agent
# 0.4.1). Polls every 5 s for 2 min what the agent sees (agent.info displays/screen), what Windows reports (WMI video
# controllers) and the agent's log lines about displays. One lab lock; the disposable is deleted at the end.
param([string]$Template = 'agent-tpl', [string]$Name = 'agent051-dd', [string]$Me = 'agent-guest')
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
function Step($m) { "[$(Get-Date -Format HH:mm:ss)] $m" | Out-Host }
& (Join-Path $repo 'labs\042-admin-dock\take-lock.ps1') -What "lab 051: display diagnosis on disposable $Name" -Me $Me -MaxMinutes 60
if ($LASTEXITCODE -ne 0) { throw 'no lock' }
try {
    New-GpuVM -Name $Name -Template $Template -Disposable -Use agent -Override @{ vm = @{ memoryGB = 4; cpu = @{ count = 4 } } } -Confirm:$false | Out-Null
    Step 'created'
    $gc = & (Get-Module GpuVM) { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $Name
    for ($i = 0; $i -lt 24; $i++) {
        $a = try { Invoke-GpuVMAgent -Name $Name -Method agent.info -TimeoutSec 5 } catch { $null }
        $w = try { Invoke-Command -VMName $Name -Credential $gc -ErrorAction Stop {
                @(Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name)=$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)/$($_.Status)" }) -join '; ' } } catch { 'psd: ' + $_.Exception.Message.Substring(0, 40) }
        $d = if ($a -and $a.ok) { ($a.result.displays | ForEach-Object { "$($_.device) $($_.adapter) $($_.rect -join ',') p=$($_.primary)" }) -join ' | ' } else { "agent: $($a.error.code)" }
        Step "agent: $d ; screen $($a.result.screen | ConvertTo-Json -Compress) ; WMI: $w"
        Start-Sleep -Seconds 5
    }
    Invoke-Command -VMName $Name -Credential $gc { Get-Content C:\ProgramData\GpuVM\Agent\logs\agent.log -Encoding UTF8 | Select-String 'display|helper .* up|started in' | Select-Object -Last 12 | ForEach-Object Line } | ForEach-Object { Step "log: $_" }
}
catch { Step "FAILED: $($_.Exception.Message)"; throw }
finally {
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 5
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    Step "VM left: $([bool](Get-VM -Name $Name -ErrorAction SilentlyContinue)); lock released"
}
