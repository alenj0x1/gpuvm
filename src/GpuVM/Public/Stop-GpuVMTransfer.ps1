function Stop-GpuVMTransfer {
    <#
    .SYNOPSIS
    Cancels a Send-GpuVMFile that is running (by its -TransferId). What was copied so far is deleted in the VM.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{8,32}$')][string]$TransferId)
    Assert-Admin
    $marker = Get-TransferMarker -Id $TransferId
    New-Item -ItemType Directory -Force -Path (Split-Path $marker) | Out-Null
    Set-Content -LiteralPath $marker -Value 'cancel'
    [ordered]@{ transferId = $TransferId }
}
