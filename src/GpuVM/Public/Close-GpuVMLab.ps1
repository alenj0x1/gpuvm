function Close-GpuVMLab {
    <#
    .SYNOPSIS
    Closes a lab with its conclusion. If adopted, move the change into the corresponding profile.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Lab,
        [Parameter(Mandatory)][ValidateSet('adopted', 'rejected', 'inconclusive')][string]$Status,
        [Parameter(Mandatory)][string]$Conclusion
    )
    $data = Read-Lab $Lab
    $data['status'] = $Status
    $data['conclusion'] = $Conclusion
    $data['closedAt'] = (Get-Date).ToString('o')
    Save-Lab $data
    if ($Status -eq 'adopted') {
        Write-Step 'Remember to carry the candidate settings over to the matching profile in profiles/.'
    }
    Get-GpuVMLab -Lab $Lab
}
