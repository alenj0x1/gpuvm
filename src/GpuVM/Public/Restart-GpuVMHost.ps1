function Restart-GpuVMHost {
    <#
    .SYNOPSIS
    Restarts this PC in a few seconds, to finish turning on Virtual Machine Platform. Only while that is pending.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Assert-Admin
    if (-not (Get-GpuVMPlatform)['restartPending']) { throw "Nothing GpuVM needs is waiting for a restart." }
    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Restart')) {
        & (Join-Path $env:SystemRoot 'System32\shutdown.exe') /r /t 5
        if ($LASTEXITCODE) { throw "Windows didn't start the restart (error $LASTEXITCODE)." }
        [ordered]@{ restarting = $true }
    }
}
