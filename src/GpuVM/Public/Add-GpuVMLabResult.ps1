function Add-GpuVMLabResult {
    <#
    .SYNOPSIS
    Records a measurement in a lab. Repeat the measurement several times per variant to average it.
    .EXAMPLE
    Add-GpuVMLabResult -Lab 002 -Variant candidate -Metric '3DMark Time Spy (GPU)' -Value 10480 -Unit pts
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Lab,
        [Parameter(Mandatory)][ValidateSet('baseline', 'candidate')][string]$Variant,
        [Parameter(Mandatory)][string]$Metric,
        [Parameter(Mandatory)][double]$Value,
        [string]$Unit = '',
        [switch]$LowerIsBetter,
        [string]$Notes
    )
    $data = Read-Lab $Lab
    if ($data['status'] -ne 'open') { throw "El laboratorio $($data['id']) ya está cerrado ($($data['status']))." }
    $data['results'] = @($data['results']) + [ordered]@{
        variant       = $Variant
        metric        = $Metric
        value         = $Value
        unit          = $Unit
        lowerIsBetter = [bool]$LowerIsBetter
        notes         = $Notes
        at            = (Get-Date).ToString('o')
    }
    Save-Lab $data
    Get-LabSummary $data | Where-Object Metric -eq $Metric
}
