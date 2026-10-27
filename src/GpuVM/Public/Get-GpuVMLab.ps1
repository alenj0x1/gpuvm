function Get-GpuVMLab {
    <#
    .SYNOPSIS
    Without -Lab, lists the labs. With -Lab, shows the hypothesis and the per-metric comparison.
    #>
    [CmdletBinding()]
    param([string]$Lab)
    if (-not $Lab) {
        return Get-ChildItem (Get-LabRoot) -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'lab.json') } |
            ForEach-Object {
                $data = Read-JsonFile (Join-Path $_.FullName 'lab.json')
                [pscustomobject]@{
                    Id      = $data['id']
                    Title   = $data['title']
                    Status  = $data['status']
                    Results = @($data['results']).Count
                }
            }
    }
    $data = Read-Lab $Lab
    [pscustomobject]@{
        PSTypeName = 'GpuVM.Lab'
        Id         = $data['id']
        Title      = $data['title']
        Hypothesis = $data['hypothesis']
        Status     = $data['status']
        Conclusion = $data['conclusion']
        Metrics    = @(Get-LabSummary $data)
        Path       = $data['path']
    }
}
