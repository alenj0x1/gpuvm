Set-StrictMode -Version 3.0

$script:ModuleRoot  = $PSScriptRoot
$script:RepoRoot    = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
# Mutable data (labs, downloads) lives apart from the code. When installed under Program Files (where the
# code is read-only for the user), it goes to %ProgramData%\GpuVM, which is restricted to administrators.
$script:DataRoot = if ($env:GPUVM_DATA) { $env:GPUVM_DATA }
    elseif ($env:ProgramFiles -and $script:RepoRoot.StartsWith($env:ProgramFiles, [StringComparison]::OrdinalIgnoreCase)) { Join-Path $env:ProgramData 'GpuVM' }
    else { $script:RepoRoot }
$script:ToolVersion = '0.1.1'
$script:Backends    = @{}
# Previous GPU counter sample (Get-GpuUsageByProcess computes usage between two samples).
$script:GpuEngineCategory = $null
$script:GpuEnginePrevious = $null

# Order matters: Private defines helpers, Backends register themselves, Public exposes commands.
foreach ($folder in 'Private', 'Backends', 'Public') {
    $dir = Join-Path $PSScriptRoot $folder
    if (Test-Path $dir) {
        Get-ChildItem $dir -Filter *.ps1 | Sort-Object Name | ForEach-Object { . $_.FullName }
    }
}

Export-ModuleMember -Function (Get-ChildItem (Join-Path $PSScriptRoot 'Public') -Filter *.ps1).BaseName
