function Get-LabRoot {
    if ($env:GPUVM_LABS_ROOT) { return $env:GPUVM_LABS_ROOT }
    Get-DataPath 'labs'
}

function Get-LabDirectory {
    param([Parameter(Mandatory)][string]$Id)
    $found = @(Get-ChildItem (Get-LabRoot) -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$Id*" -and (Test-Path (Join-Path $_.FullName 'lab.json')) })
    if ($found.Count -eq 0) { throw "No existe el laboratorio '$Id'." }
    if ($found.Count -gt 1) { throw "'$Id' coincide con varios laboratorios: $($found.Name -join ', ')" }
    $found[0].FullName
}

function Read-Lab {
    param([Parameter(Mandatory)][string]$Id)
    $dir = Get-LabDirectory $Id
    $lab = Read-JsonFile (Join-Path $dir 'lab.json')
    $lab['path'] = $dir
    $lab
}

function Save-Lab {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Lab)
    $copy = Merge-Hashtable -Base $Lab
    $copy.Remove('path')
    Write-JsonFile -Path (Join-Path $Lab['path'] 'lab.json') -Data $copy
}

# Averages each metric per variant and computes the candidate's difference against the baseline.
function Get-LabSummary {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Lab)
    $results = @($Lab['results'])
    foreach ($group in ($results | Group-Object { $_['metric'] })) {
        $first = $group.Group[0]
        $avg = {
            param($variant)
            $values = @($group.Group | Where-Object { $_['variant'] -eq $variant } | ForEach-Object { [double]$_['value'] })
            if ($values.Count) { ($values | Measure-Object -Average).Average } else { $null }
        }
        $baseline = & $avg 'baseline'
        $candidate = & $avg 'candidate'
        $delta = if ($null -ne $baseline -and $null -ne $candidate -and $baseline -ne 0) { [math]::Round(($candidate - $baseline) / [math]::Abs($baseline) * 100, 2) } else { $null }
        $better = if ($null -eq $delta) { $null } elseif ($first['lowerIsBetter']) { $delta -lt 0 } else { $delta -gt 0 }
        [pscustomobject]@{
            PSTypeName = 'GpuVM.LabMetric'
            Metric     = $group.Name
            Unit       = $first['unit']
            Baseline   = $baseline
            Candidate  = $candidate
            DeltaPct   = $delta
            Better     = $better
            Runs       = $group.Count
        }
    }
}
