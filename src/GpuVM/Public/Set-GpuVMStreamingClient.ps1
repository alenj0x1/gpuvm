function Set-GpuVMStreamingClient {
    <#
    .SYNOPSIS
    Changes the resolution, FPS, V-Sync, frame pacing, mouse or other values Moonlight uses to open the VM. Does not require shutting it down.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidatePattern('^\d{3,5}x\d{3,5}$')][string]$Resolution,
        # 0 = the host monitor's refresh rate, read each time the VM is opened (lab 022).
        [ValidateScript({ $_ -eq 0 -or ($_ -ge 10 -and $_ -le 480) })][int]$Fps,
        [ValidateRange(0, 500000)][int]$BitrateKbps = -1,
        [ValidateSet('auto', 'H.264', 'HEVC', 'AV1')][string]$Codec,
        # windowed: a window the size of the resolution, which can be resized.
        [ValidateSet('fullscreen', 'windowed', 'borderless')][string]$DisplayMode,
        # Unset = leave as is. V-Sync shows each frame whole; frame pacing evens them out (labs 020 and 021).
        [Nullable[bool]]$VSync,
        [Nullable[bool]]$FramePacing,
        # capture: the VM takes the mouse (games); absolute: the pointer moves freely, as in remote desktop.
        [ValidateSet('capture', 'absolute')][string]$Mouse
    )
    $state = Get-GpuVMState -Name $Name
    if (-not $state['config']['streaming']) { throw "La VM '$Name' no tiene streaming." }
    $client = $state['config']['streaming']['client']
    if ($Resolution) { $client['resolution'] = $Resolution }
    if ($PSBoundParameters.ContainsKey('Fps')) { $client['fps'] = $Fps }
    if ($BitrateKbps -ge 0) { $client['bitrateKbps'] = $BitrateKbps }
    if ($Codec) { $client['codec'] = $Codec }
    if ($DisplayMode) { $client['displayMode'] = $DisplayMode }
    if ($null -ne $VSync) { $client['vsync'] = $VSync }
    if ($null -ne $FramePacing) { $client['framePacing'] = $FramePacing }
    if ($Mouse) { $client['mouse'] = $Mouse }
    # Moonlight only paces frames with V-Sync on.
    if ($client.Contains('vsync') -and $client['vsync'] -eq $false) { $client['framePacing'] = $false }
    Save-GpuVMState $state
    $client
}
