function Set-GpuVMStreamingClient {
    <#
    .SYNOPSIS
    Changes the resolution, FPS or other values Moonlight uses to open the VM. Does not require shutting it down.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidatePattern('^\d{3,5}x\d{3,5}$')][string]$Resolution,
        [ValidateRange(10, 480)][int]$Fps,
        [ValidateRange(0, 500000)][int]$BitrateKbps = -1,
        [ValidateSet('auto', 'H.264', 'HEVC', 'AV1')][string]$Codec
    )
    $state = Get-GpuVMState -Name $Name
    if (-not $state['config']['streaming']) { throw "La VM '$Name' no tiene streaming." }
    $client = $state['config']['streaming']['client']
    if ($Resolution) { $client['resolution'] = $Resolution }
    if ($Fps) { $client['fps'] = $Fps }
    if ($BitrateKbps -ge 0) { $client['bitrateKbps'] = $BitrateKbps }
    if ($Codec) { $client['codec'] = $Codec }
    Save-GpuVMState $state
    $client
}
