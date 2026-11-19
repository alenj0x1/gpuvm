function Set-GpuVMDisposable {
    <#
    .SYNOPSIS
    Keeps a disposable machine: it stops being deleted when it turns off and becomes a normal machine. The other way
    is not possible on purpose (a machine can only be disposable from the moment it is made).
    .EXAMPLE
    Set-GpuVMDisposable -Name juegos-desechable -Keep
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name,
        [Parameter(Mandatory)][switch]$Keep
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    if (-not (Test-GpuVMDisposable -State $state)) { return [ordered]@{ name = $Name; disposable = $false } }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Keep the machine')) { return }
    $state.Remove('disposable')
    $state['keptAt'] = (Get-Date).ToString('o')
    Save-GpuVMState $state
    Write-Step "The machine '$Name' is kept"
    [ordered]@{ name = $Name; disposable = $false }
}
