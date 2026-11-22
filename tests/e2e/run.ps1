<#
.SYNOPSIS
GpuVM's end-to-end suite: drives the installed app like the person and an agent, and checks what is on screen.

.DESCRIPTION
Runs every suite in tests/e2e/suites (or the ones named), sharing one disposable machine made by an agent session.
A full pass on a clean checkout is recorded in tests/e2e/.last-pass.json; scripts/release.py refuses to release a
commit without one. Needs GpuVM installed and running, the agent-tpl template, ~4 GB of free memory, and nobody
using the mouse or keyboard while it runs (it clicks and types).

.EXAMPLE
pwsh -File tests/e2e/run.ps1
.EXAMPLE
pwsh -File tests/e2e/run.ps1 -Suite agent-overlays,app-pages -KeepMachine
#>
param(
    [string[]]$Suite,
    [string]$Template = 'agent-tpl',
    [string]$Exe = 'C:\Program Files\GpuVM\gpuvm.exe',
    [string]$Out = (Join-Path ([IO.Path]::GetTempPath()) "gpuvm-e2e-$(Get-Date -Format yyyyMMdd-HHmmss)"),
    [switch]$KeepMachine
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'E2E.psm1') -Force -DisableNameChecking
Start-E2ERun $Out
if (-not (Get-App)) { throw 'GpuVM is not running.' }

$files = Get-ChildItem (Join-Path $PSScriptRoot 'suites') -Filter *.ps1 | Sort-Object Name
if ($Suite) { $files = $files | Where-Object { $Suite -contains $_.BaseName -or $Suite -contains ($_.BaseName -replace '^\d+-', '') } }
$all = -not $Suite

$ctx = [pscustomobject]@{ Exe = $Exe; Template = $Template; Out = $Out; Mcp = $null; Machine = $null }
try {
    $ctx.Mcp = Start-Mcp $Exe
    foreach ($f in $files) {
        Write-Host "`n== $($f.BaseName)"
        . $f.FullName
        try { & (Get-Item "function:Test-Suite").ScriptBlock $ctx }
        catch { Check "$($f.BaseName) ran to the end" $false $_.Exception.Message }
        Remove-Item function:Test-Suite -ErrorAction SilentlyContinue
    }
}
finally {
    if ($ctx.Machine -and -not $KeepMachine) { try { $null = Invoke-Tool $ctx.Mcp 'destroy' @{ machine = $ctx.Machine; force = $true } } catch { } }
    if ($ctx.Mcp) { Stop-Mcp $ctx.Mcp }
}

$results = Get-E2EResults
$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "`n$($results.Count - $failed.Count) of $($results.Count) passed. Screenshots: $Out"
if (-not $failed.Count -and $all) {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    if (git -C $repo status --porcelain) { Write-Host 'Not recorded for the release: uncommitted changes.' }
    else {
        $commit = (git -C $repo rev-parse HEAD).Trim()
        [ordered]@{ commit = $commit; exe = (Get-FileHash -LiteralPath $Exe).Hash; at = (Get-Date).ToUniversalTime().ToString('o'); checks = $results.Count } |
            ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $PSScriptRoot '.last-pass.json')
        Write-Host "Recorded for the release: commit $commit."
    }
}
exit [int]($failed.Count -gt 0)
