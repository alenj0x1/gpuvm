# Lab 052: the viewer's FIRST open after a copy is made (black in every variant so far). -Runs fresh copies, each
# opened twice by viewer-black.mjs with the given variant, all under one hold of the shared lab lock (each run takes
# and releases it; the queue keeps this session first). Copies are deleted by each run. Run elevated.
# -Variant '' (default): GpuVM as installed, no lab help (to measure the app's own burst and ordering).
param([int]$Runs = 4, [string]$Variant = '')
$ErrorActionPreference = 'Stop'
$env:LAB052_VARIANT = $Variant
for ($i = 1; $i -le $Runs; $i++) {
    Write-Host "=== run $i of $Runs ($(if ($Variant) { $Variant } else { "as installed" }))"
    & (Join-Path $PSScriptRoot 'viewer-black.ps1') -Connects 2 -Label "first-$(if ($Variant) { $Variant } else { "installed" })-$i"
}
