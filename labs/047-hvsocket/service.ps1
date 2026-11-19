# Registers (or with -Remove, unregisters) the lab's Hyper-V socket service GUID on the host:
#   HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices\{guid}  ElementName
# Never touches an existing key it didn't create: if the GUID is already registered by someone else it stops.
# A marker value (GpuVMLab = 047) proves the key is ours before -Remove deletes it. Run elevated.
param(
    [string]$Guid = 'b1c0a047-6a5e-4c4b-9e47-047047047047',
    [string]$Name = 'GpuVM lab 047 hvsocket',
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'
$base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices'
$key = Join-Path $base $Guid
if ($Remove) {
    if (-not (Test-Path $key)) { "not registered"; return }
    if ((Get-ItemProperty $key).GpuVMLab -ne '047') { throw "$key exists but isn't ours; left as is." }
    Remove-Item $key
    "removed $Guid"
    return
}
if (Test-Path $key) {
    if ((Get-ItemProperty $key).GpuVMLab -eq '047') { "already registered $Guid"; return }
    throw "$key already exists (not ours); pick another GUID."
}
New-Item $key | Out-Null
New-ItemProperty $key -Name ElementName -Value $Name -PropertyType String | Out-Null
New-ItemProperty $key -Name GpuVMLab -Value '047' -PropertyType String | Out-Null
"registered $Guid"
