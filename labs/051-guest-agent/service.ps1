# Registers (or with -Remove, unregisters) the GpuVM agent service GUID (docs/agents/protocol.md) on the host:
#   HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices\{guid}  ElementName
# If it is already registered by someone else (the broker), it is used as is and never removed. A marker value
# (GpuVMLab = 051) proves the key is ours before -Remove deletes it. Run elevated.
param(
    [string]$Guid = '94aca5ef-a5b6-45a9-8c15-c7724a63f3da',
    [string]$Name = 'GpuVM agent',
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'
$base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices'
$key = Join-Path $base $Guid
if ($Remove) {
    if (-not (Test-Path $key)) { "not registered"; return }
    if ((Get-ItemProperty $key).GpuVMLab -ne '051') { throw "$key exists but isn't ours; left as is." }
    Remove-Item $key
    "removed $Guid"
    return
}
if (Test-Path $key) {
    if ((Get-ItemProperty $key).GpuVMLab -eq '051') { "already registered $Guid"; return }
    "already registered by someone else (GpuVM's broker?): used as is, left in place"; return
}
New-Item $key | Out-Null
New-ItemProperty $key -Name ElementName -Value $Name -PropertyType String | Out-Null
New-ItemProperty $key -Name GpuVMLab -Value '051' -PropertyType String | Out-Null
"registered $Guid"
