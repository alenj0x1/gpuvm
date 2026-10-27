function New-GpuVMLab {
    <#
    .SYNOPSIS
    Opens a lab: a hypothesis, a baseline configuration and a candidate to compare with metrics.
    .EXAMPLE
    New-GpuVMLab -Title 'SMT topology' -Hypothesis 'Exposing 2 threads per core raises FPS in heavily threaded games' `
        -BaselineProfile balanced -CandidateOverride @{ vm = @{ cpu = @{ hwThreadsPerCore = 2 } } }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Hypothesis,
        [string]$VM,
        [string]$BaselineProfile = 'balanced',
        [hashtable]$BaselineOverride,
        [string]$CandidateProfile,
        [hashtable]$CandidateOverride
    )
    $root = Get-LabRoot
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $last = Get-ChildItem $root -Directory | Where-Object Name -match '^(\d{3})-' | ForEach-Object { [int]$Matches[1] } | Sort-Object | Select-Object -Last 1
    $number = '{0:D3}' -f ([int]$last + 1)
    $id = "$number-$(ConvertTo-Slug $Title)"
    $dir = Join-Path $root $id
    New-Item -ItemType Directory -Path $dir | Out-Null

    $lab = [ordered]@{
        id         = $id
        title      = $Title
        hypothesis = $Hypothesis
        vm         = $VM
        status     = 'open'
        createdAt  = (Get-Date).ToString('o')
        variants   = [ordered]@{
            baseline  = [ordered]@{ profile = $BaselineProfile; override = $BaselineOverride }
            candidate = [ordered]@{ profile = ($CandidateProfile ? $CandidateProfile : $BaselineProfile); override = $CandidateOverride }
        }
        results    = @()
        conclusion = $null
        path       = $dir
    }
    Save-Lab $lab
    Set-Content -LiteralPath (Join-Path $dir 'notes.md') -Encoding utf8 -Value @"
# $Title

**Hypothesis:** $Hypothesis

## Procedure

1. Apply the baseline: ``Set-GpuVM -Name <vm> -Profile $BaselineProfile``
2. Measure and record with ``Add-GpuVMLabResult -Lab $number -Variant baseline ...``
3. Apply the candidate and repeat with ``-Variant candidate``.
4. Close with ``Close-GpuVMLab -Lab $number -Status adopted|rejected|inconclusive -Conclusion '...'``

## Observations

"@
    Get-GpuVMLab -Lab $number
}
