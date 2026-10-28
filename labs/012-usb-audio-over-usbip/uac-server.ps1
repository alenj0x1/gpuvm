# Runs GpuVM's USB speaker server inside the VM (task "GpuVM-Lab012-UAC", as SYSTEM). Windows PowerShell 5.1.
param([int]$Port = 3240)
Add-Type -Path (Join-Path $PSScriptRoot 'UsbAudioServer.cs')
[UsbAudioServer]::Run($Port, (Join-Path $PSScriptRoot 'server.log'), (Join-Path $PSScriptRoot 'status.json'))
