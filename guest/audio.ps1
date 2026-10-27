# "GpuVM-Audio" task: runs at logon until the VB-CABLE output shows up; then it
# configures Sunshine to capture it and removes itself. Windows PowerShell 5.1.
$root = 'C:\GpuVM'
. (Join-Path $root 'streaming.ps1')

# Windows localizes the playback endpoint name ("CABLE Input" in English, "Altavoces" in Spanish),
# so it is found by being a render endpoint ({0.0.0.…}) of the VB-Audio cable.
$endpoint = Get-PnpDevice -Class AudioEndpoint -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -like 'SWD\MMDEVAPI\{0.0.0.*' -and $_.FriendlyName -like '*VB-Audio Virtual Cable*' -and $_.Status -eq 'OK' } |
    Sort-Object { $_.FriendlyName -like '*16 Ch*' } |
    Select-Object -First 1
if (-not $endpoint) { exit 0 }

Start-Transcript -Path (Join-Path $root 'audio.log') -Append | Out-Null
try {
    # virtual_sink makes Sunshine switch the default output to the cable while streaming.
    $conf = Join-Path $env:ProgramFiles 'Sunshine\config\sunshine.conf'
    Set-SunshineConfig -Path $conf -Settings ([ordered]@{ virtual_sink = $endpoint.FriendlyName })
    Get-Service | Where-Object { $_.Name -like 'Sunshine*' -or $_.DisplayName -like '*Sunshine*' } | Restart-Service -Force -ErrorAction SilentlyContinue

    [pscustomobject]@{ configuredAt = (Get-Date).ToString('o'); sink = $endpoint.FriendlyName } |
        ConvertTo-Json | Set-Content (Join-Path $root 'audio.done.json') -Encoding UTF8
    Unregister-ScheduledTask -TaskName 'GpuVM-Audio' -Confirm:$false
    Write-Host "Sunshine captura el audio de '$($endpoint.FriendlyName)'"
}
finally {
    Stop-Transcript | Out-Null
}
