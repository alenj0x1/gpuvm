# Windows administrator prompts in a VM captured with WGC (guest\admin-prompt.ps1, labs 025 and 026): the guest
# publishes the open prompt through Hyper-V's data exchange, the app shows it on the host, and the person's answer is
# carried back through PowerShell Direct. Only the host can give that order; nothing in the guest can answer for itself.

$script:AdminPromptDir = 'C:\Program Files\GpuVM\AdminPrompt'

# Installs or updates the watcher in the guest when its code changed (by hash). Returns $true when it (re)installed.
function Install-GuestAdminPrompt {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    $source = Get-RepoPath 'guest\admin-prompt.ps1'
    $code = Get-Content -Raw -LiteralPath $source
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash
    $answer = Invoke-Guest -Name $Name -Credential $Credential -ArgumentList $code, $hash, $script:AdminPromptDir -ScriptBlock {
        param($code, $hash, $dir)
        $file = Join-Path $dir 'admin-prompt.ps1'
        $task = Get-ScheduledTask -TaskName 'GpuVM-AdminPrompt' -ErrorAction SilentlyContinue
        if ((Test-Path $file) -and (Get-FileHash -Algorithm SHA256 $file).Hash -eq $hash -and $task) {
            if ($task.State -ne 'Running') { Start-ScheduledTask -TaskName 'GpuVM-AdminPrompt' }
            return 'unchanged'
        }
        # Under Program Files: only administrators can change what runs as SYSTEM.
        New-Item -ItemType Directory -Force $dir | Out-Null
        [IO.File]::WriteAllText($file, $code, [Text.UTF8Encoding]::new($true))
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$file`" -Mode watch"
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        if ($task) { Stop-ScheduledTask -TaskName 'GpuVM-AdminPrompt' -ErrorAction SilentlyContinue }
        Register-ScheduledTask -TaskName 'GpuVM-AdminPrompt' -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) `
            -User SYSTEM -RunLevel Highest -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName 'GpuVM-AdminPrompt'
        'installed'
    }
    (ConvertTo-GuestString (@($answer)[-1])) -eq 'installed'
}

# The administrator prompt open in the guest, read from Hyper-V's data exchange (~100 ms, no PowerShell Direct):
# $null when none, else { id, app, publisher }. Everything comes from the guest, so it is rebuilt from short strings.
function Get-GuestAdminPrompt {
    param([Parameter(Mandatory)][string]$Name)
    $vm = Get-VM -Name $Name -ErrorAction Stop
    if ($vm.State -ne 'Running') { return $null }
    $kvp = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_KvpExchangeComponent -Filter "SystemName='$($vm.Id.Guid.ToUpper())'" -ErrorAction SilentlyContinue
    foreach ($item in @($kvp.GuestExchangeItems)) {
        if (-not $item) { continue }
        $xml = [xml]$item
        if ($xml.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Name']/VALUE").InnerText -ne 'GpuVMAdminPrompt') { continue }
        $data = try { $xml.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Data']/VALUE").InnerText | ConvertFrom-Json } catch { $null }
        if (-not $data -or $data.open -ne $true) { return $null }
        $id = 0
        if (-not [int]::TryParse([string]$data.id, [ref]$id) -or $id -le 0) { return $null }
        return [pscustomobject]@{
            id        = $id
            app       = ConvertTo-GuestString $data.app -MaxLength 80
            publisher = ConvertTo-GuestString $data.publisher -MaxLength 80
        }
    }
    $null
}

# Presses Yes or No on the guest's prompt if it is still the one with -PromptId. Runs as SYSTEM in the guest (a
# one-time task): reaching the secure desktop needs it. Returns done, changed (another prompt, or none) or error: ...
function Invoke-GuestAdminPromptAnswer {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$Answer,
        [Parameter(Mandatory)][int]$PromptId
    )
    # $reply, not $answer: PowerShell ignores case and $Answer is the validated parameter.
    $reply = Invoke-Guest -Name $Name -Credential $Credential -ArgumentList $Answer, $PromptId, $script:AdminPromptDir -ScriptBlock {
        param($answer, $promptId, $dir)
        $file = Join-Path $dir 'admin-prompt.ps1'
        if (-not (Test-Path $file)) { return 'error: no está instalado' }
        $out = Join-Path $dir 'answer.txt'
        Remove-Item $out -ErrorAction SilentlyContinue
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"& '$file' -Mode answer -Action $answer -PromptId $promptId | Set-Content '$out'`""
        Register-ScheduledTask -TaskName 'GpuVM-AdminPromptAnswer' -Action $action -User SYSTEM -RunLevel Highest -Force | Out-Null
        try {
            Start-ScheduledTask -TaskName 'GpuVM-AdminPromptAnswer'
            for ($i = 0; $i -lt 60 -and -not (Test-Path $out); $i++) { Start-Sleep -Milliseconds 250 }
            if (Test-Path $out) { (Get-Content $out -Raw).Trim() } else { 'error: sin respuesta' }
        }
        finally { Unregister-ScheduledTask -TaskName 'GpuVM-AdminPromptAnswer' -Confirm:$false -ErrorAction SilentlyContinue }
    }
    ConvertTo-GuestString (@($reply)[-1]) -MaxLength 120
}
