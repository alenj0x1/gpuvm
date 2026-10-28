# Guest first logon (launched by unattend.xml). Windows PowerShell 5.1.
$ErrorActionPreference = 'Continue'
$root = 'C:\GpuVM'
Start-Transcript -Path (Join-Path $root 'setup.log') -Append | Out-Null

try {
    . (Join-Path $root 'optimizations.ps1')
    $config = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'guest-config.json') | ConvertFrom-Json

    # Make sure the account is an administrator even if the group name did not match the language.
    $admins = Get-LocalGroup -SID 'S-1-5-32-544'
    if (-not (Get-LocalGroupMember -Group $admins -ErrorAction SilentlyContinue | Where-Object Name -like "*\$env:USERNAME")) {
        Add-LocalGroupMember -Group $admins -Member $env:USERNAME -ErrorAction SilentlyContinue
    }

    $applied = @()
    foreach ($name in $config.optimizations) {
        if (-not $GpuVMOptimizations.Contains($name)) {
            Write-Warning "Optimización desconocida: $name"
            continue
        }
        Write-Host "Aplicando $name — $($GpuVMOptimizations[$name].Description)"
        try {
            & $GpuVMOptimizations[$name].Apply
            $applied += $name
        }
        catch {
            Write-Warning "Falló ${name}: $_"
        }
    }

    $streaming = $null
    if (Test-Path (Join-Path $root 'streaming\streaming-config.json')) {
        . (Join-Path $root 'streaming.ps1')
        $streaming = Install-GpuVMStreaming -Root $root
        $streaming.GetEnumerator() | ForEach-Object { Write-Host "Streaming $($_.Key): $($_.Value)" }
    }

    $gpus = Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, Status
    [pscustomobject]@{
        finishedAt    = (Get-Date).ToString('o')
        optimizations = $applied
        streaming     = $streaming
        rebootPending = [bool]($streaming -and $streaming.hyperVVideo -eq 'disabled')
        gpus          = $gpus
    } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root 'setup.done.json') -Encoding UTF8
}
finally {
    # unattend.xml stores the password in plain text; delete it as soon as it is no longer needed.
    Remove-Item 'C:\Windows\Panther\unattend.xml' -Force -ErrorAction SilentlyContinue
    Stop-Transcript | Out-Null
}

# A restart leaves the virtual display as the only one; automatic logon signs back in.
# Audio needs no restart: usbip-win2 attaches GpuVM's speaker again every time Windows starts.
if ($streaming -and $streaming.hyperVVideo -eq 'disabled') {
    shutdown.exe /r /t 15 /c "GpuVM: reinicio para terminar de instalar el streaming"
}
