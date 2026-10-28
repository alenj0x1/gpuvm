Set-StrictMode -Version 3.0

$script:ModuleRoot  = $PSScriptRoot
$script:RepoRoot    = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
# Mutable data (labs, downloads) lives apart from the code. When installed under Program Files (where the
# code is read-only for the user), it goes to %ProgramData%\GpuVM, which is restricted to administrators.
# GPUVM_* overrides (for tests) are ignored when elevated: the user's environment must not redirect an admin process.
$script:IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$script:DataRoot = if ($env:GPUVM_DATA -and -not $script:IsElevated) { $env:GPUVM_DATA }
    elseif ($script:RepoRoot.StartsWith([Environment]::GetFolderPath('ProgramFiles'), [StringComparison]::OrdinalIgnoreCase)) { Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'GpuVM' }
    else { $script:RepoRoot }
$script:ToolVersion = '0.2.0'
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
