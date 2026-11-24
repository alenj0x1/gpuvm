function Enable-GpuVMPlatform {
    <#
    .SYNOPSIS
    Turns on Windows' "Virtual Machine Platform", which machines without Hyper-V run on. Windows finishes it at the
    next restart.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Assert-Admin
    if (-not $PSCmdlet.ShouldProcess('Virtual Machine Platform', 'Enable')) { return }
    $dism = Join-Path $env:SystemRoot 'System32\dism.exe'
    $null = & $dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart /quiet
    # 0: on now; 3010: on after a restart (DISM's codes, whatever Windows' language).
    switch ($LASTEXITCODE) {
        0 { [ordered]@{ enabled = $true; restartNeeded = -not (Get-Service vmcompute -ErrorAction SilentlyContinue) } }
        3010 { [ordered]@{ enabled = $true; restartNeeded = $true } }
        default { throw "Windows couldn't turn on Virtual Machine Platform (DISM error $LASTEXITCODE)." }
    }
}
