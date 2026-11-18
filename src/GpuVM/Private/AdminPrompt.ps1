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

# A value the guest published through Hyper-V's data exchange (~100 ms, no PowerShell Direct), parsed from JSON, or
# $null. Everything comes from the guest: callers rebuild what they use from short, checked strings.
function Get-GuestKvpJson {
    param([Parameter(Mandatory)]$VM, [Parameter(Mandatory)][string]$Key)
    $kvp = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_KvpExchangeComponent -Filter "SystemName='$($VM.Id.Guid.ToUpper())'" -ErrorAction SilentlyContinue
    foreach ($item in @($kvp.GuestExchangeItems)) {
        if (-not $item) { continue }
        $xml = [xml]$item
        if ($xml.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Name']/VALUE").InnerText -ne $Key) { continue }
        $text = $xml.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Data']/VALUE").InnerText
        if (-not $text -or $text.Length -gt 2048) { return $null }
        return $(try { $text | ConvertFrom-Json } catch { $null })
    }
    $null
}

# The administrator prompt open in the guest: $null when none, else { id, app, publisher, reading, nonce }. reading:
# the guest is still reading its program and publisher. nonce: the prompt's one-time code for an answer through the
# data exchange ($null with a watcher from before lab 042); it never leaves the module.
function Get-GuestAdminPromptState {
    param([Parameter(Mandatory)][string]$Name)
    $vm = Get-VM -Name $Name -ErrorAction Stop
    if ($vm.State -ne 'Running') { return $null }
    $data = Get-GuestKvpJson -VM $vm -Key 'GpuVMAdminPrompt'
    if ($data -isnot [pscustomobject]) { return $null }
    # Fields a watcher may not send (older ones have no nonce or reading): read without failing under strict mode.
    $field = @{}
    foreach ($p in $data.PSObject.Properties) { $field[$p.Name] = $p.Value }
    if ($field['open'] -ne $true) { return $null }
    $id = 0
    if (-not [int]::TryParse([string]$field['id'], [ref]$id) -or $id -le 0) { return $null }
    [pscustomobject]@{
        id        = $id
        app       = ConvertTo-GuestString $field['app'] -MaxLength 80
        publisher = ConvertTo-GuestString $field['publisher'] -MaxLength 80
        reading   = $field['reading'] -eq $true
        nonce     = if ([string]$field['nonce'] -cmatch '^[0-9a-f]{32}$') { [string]$field['nonce'] } else { $null }
    }
}

# The open prompt as the app sees it: { id, app, publisher, reading }, or $null.
function Get-GuestAdminPrompt {
    param([Parameter(Mandatory)][string]$Name)
    $state = Get-GuestAdminPromptState -Name $Name
    if (-not $state) { return $null }
    [pscustomobject]@{ id = $state.id; app = $state.app; publisher = $state.publisher; reading = $state.reading }
}

# A host item of Hyper-V's data exchange for a VM (Msvm_KvpExchangeDataItem, source 0): the guest sees it under
# HKLM\SOFTWARE\Microsoft\Virtual Machine\External, a key only SYSTEM and administrators can write there.
function ConvertTo-KvpItemText {
    param([Parameter(Mandatory)][string]$Key, [AllowEmptyString()][string]$Value)
    $k = [Security.SecurityElement]::Escape($Key)
    $v = [Security.SecurityElement]::Escape($Value)
    "<INSTANCE CLASSNAME=`"Msvm_KvpExchangeDataItem`"><PROPERTY NAME=`"Data`" TYPE=`"string`"><VALUE>$v</VALUE></PROPERTY><PROPERTY NAME=`"Name`" TYPE=`"string`"><VALUE>$k</VALUE></PROPERTY><PROPERTY NAME=`"Source`" TYPE=`"uint16`"><VALUE>0</VALUE></PROPERTY></INSTANCE>"
}

function Invoke-HostKvpMethod {
    param([Parameter(Mandatory)]$VM, [Parameter(Mandatory)][ValidateSet('AddKvpItems', 'ModifyKvpItems', 'RemoveKvpItems')][string]$Method,
        [Parameter(Mandatory)][string]$Key, [AllowEmptyString()][string]$Value = '')
    $svc = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService
    $system = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "Name='$($VM.Id.Guid.ToUpper())'"
    $r = Invoke-CimMethod -InputObject $svc -MethodName $Method -Arguments @{ TargetSystem = $system; DataItems = @(ConvertTo-KvpItemText $Key $Value) }
    if ($r.ReturnValue -eq 4096) {
        for ($i = 0; $i -lt 200; $i++) {
            $job = Get-CimInstance -InputObject $r.Job
            if ($job.JobState -ge 7) { if ($job.JobState -ne 7) { throw "$Method`: $($job.ErrorDescription)" }; return }
            Start-Sleep -Milliseconds 10
        }
        throw "$Method`: sin respuesta"
    }
    if ($r.ReturnValue -ne 0) { throw "$Method`: $($r.ReturnValue)" }
}

function Set-HostKvpItem {
    param([Parameter(Mandatory)]$VM, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Value)
    # Modify when it exists (a previous answer), else add.
    try { Invoke-HostKvpMethod -VM $VM -Method ModifyKvpItems -Key $Key -Value $Value }
    catch { Invoke-HostKvpMethod -VM $VM -Method AddKvpItems -Key $Key -Value $Value }
}

# Answers through the data exchange (lab 042, ~1 s instead of ~5 s): the guest's watcher presses the button only if
# the prompt open is still -PromptId with the same one-time code. Returns done, changed or error: ..., or $null when
# the guest never acknowledged it (the caller may fall back to PowerShell Direct).
function Send-GuestAdminPromptAnswer {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$Answer,
        [Parameter(Mandatory)][int]$PromptId,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$Nonce,
        [int]$TimeoutMs = 6000
    )
    $vm = Get-VM -Name $Name -ErrorAction Stop
    $value = [ordered]@{ id = $PromptId; nonce = $Nonce; answer = $Answer } | ConvertTo-Json -Compress
    Set-HostKvpItem -VM $vm -Key 'GpuVMAdminPromptAnswer' -Value $value
    try {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
            $ack = Get-GuestKvpJson -VM $vm -Key 'GpuVMAdminPromptAnswered'
            if ($ack -is [pscustomobject] -and $ack.PSObject.Properties['nonce'] -and $ack.PSObject.Properties['result'] -and [string]$ack.nonce -ceq $Nonce) {
                return ConvertTo-GuestString $ack.result -MaxLength 120
            }
            Start-Sleep -Milliseconds 50
        }
        $null
    }
    finally {
        # Used once: removed so nothing is left for the guest to read again.
        try { Invoke-HostKvpMethod -VM $vm -Method RemoveKvpItems -Key 'GpuVMAdminPromptAnswer' } catch { }
    }
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
