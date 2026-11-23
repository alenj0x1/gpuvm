<#
.SYNOPSIS
GpuVM's end-to-end suite: drives the installed app like the person and an agent, and checks what is on screen.

.DESCRIPTION
Runs every suite in tests/e2e/suites (or the ones named), sharing one disposable machine made by an agent session.
A full pass on a clean checkout is recorded in tests/e2e/.last-pass.json; scripts/release.py refuses to release a
commit without one. -Changed runs only the suites that cover what changed since that pass; -Failed runs again the
suites that failed last time. A passing run of those carries the record to the new commit when only tests or docs
changed; a change to the app needs a full run. Needs GpuVM installed and running, the agent-tpl template, ~4 GB of free memory, and nobody
using the mouse or keyboard while it runs (it clicks and types).

.EXAMPLE
pwsh -File tests/e2e/run.ps1
.EXAMPLE
pwsh -Command "& tests/e2e/run.ps1 -Suite agent-overlays,app-pages -KeepMachine"
.EXAMPLE
pwsh -File tests/e2e/run.ps1 -Changed
.EXAMPLE
pwsh -File tests/e2e/run.ps1 -Failed
#>
param(
    [string[]]$Suite,
    [string]$Template = 'agent-tpl',
    [string]$Exe = 'C:\Program Files\GpuVM\gpuvm.exe',
    [string]$Out = (Join-Path ([IO.Path]::GetTempPath()) "gpuvm-e2e-$(Get-Date -Format yyyyMMdd-HHmmss)"),
    [switch]$KeepMachine,
    [switch]$Changed,
    [switch]$Failed
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'E2E.psm1') -Force -DisableNameChecking
Start-E2ERun $Out
if (-not (Get-App)) { throw 'GpuVM is not running.' }

$files = Get-ChildItem (Join-Path $PSScriptRoot 'suites') -Filter *.ps1 | Sort-Object Name
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$stampPath = Join-Path $PSScriptRoot '.last-pass.json'
$lastRunPath = Join-Path $PSScriptRoot '.last-run.json'
$stamp = if (Test-Path -LiteralPath $stampPath) { Get-Content -Raw -LiteralPath $stampPath | ConvertFrom-Json } else { $null }

# Which suites cover a changed file. $null: every suite (shared test code, or app code no rule knows).
function Get-CoveringSuites([string]$Path) {
    $p = $Path -replace '\\', '/'
    if ($p -match '^tests/e2e/suites/(\d+-[\w-]+)\.ps1$') { return , @($Matches[1]) }
    if ($p -match '^tests/e2e/') { return $null }
    $rules = [ordered]@{
        '^app/src-tauri/src/(viewer|overlay|status)\.rs$' = '15-machine-ui', '30-agent-overlays', '35-person-input', '40-person-viewer', '55-settings-library'
        '^app/src-tauri/src/agent\.rs$'                   = '20-agent-tools', '25-agent-more', '30-agent-overlays', '35-person-input', '55-settings-library'
        '^app/src-tauri/src/mcp/'                         = '20-agent-tools', '25-agent-more', '35-person-input', '55-settings-library'
        '^app/src-tauri/src/(capture|recording|replay)'   = '35-person-input', '40-person-viewer', '55-settings-library'
        '^app/src-tauri/src/(lib|tray|notices|diag)\.rs$' = '10-app-pages', '50-system', '95-tray-notices'
        '^app/host/'                                      = '20-agent-tools', '25-agent-more', '50-system', '90-shutdown'
        '^app/src/(Preferences|prefs|PlacementEditor)'    = '10-app-pages', '55-settings-library'
        '^app/src/(StatusNotch|AgentDock|AgentLive|ViewerWidgets)' = '30-agent-overlays', '35-person-input'
        '^app/src/'                                       = '10-app-pages', '15-machine-ui', '55-settings-library'
        '^src/GpuVM/'                                     = '15-machine-ui', '20-agent-tools', '25-agent-more', '90-shutdown'
        '^guest/'                                         = '20-agent-tools', '25-agent-more', '35-person-input'
        '^viewer/'                                        = '30-agent-overlays', '35-person-input', '40-person-viewer'
    }
    foreach ($r in $rules.Keys) { if ($p -match $r) { return , @($rules[$r]) } }
    if ($p -match '^(app|src|guest|viewer|installer|scripts)/') { return $null }
    , @()
}
function Test-AppCode([string]$Path) { ($Path -replace '\\', '/') -match '^(app|src|guest|viewer|installer)/' }

function Get-ChangedFiles {
    $base = if ($stamp) { $stamp.commit } else { $null }
    $list = @()
    if ($base) { $list += @(git -C $repo diff --name-only "$base..HEAD") }
    $list += @(git -C $repo diff --name-only HEAD)
    $list += @(git -C $repo ls-files --others --exclude-standard)
    @($list | Where-Object { $_ } | Sort-Object -Unique)
}

if ($Changed) {
    if (-not $stamp) { throw 'No recorded full pass to compare with: run the whole suite once (no -Changed).' }
    $want = [System.Collections.Generic.HashSet[string]]::new()
    $everything = $false
    foreach ($f in Get-ChangedFiles) {
        $c = Get-CoveringSuites $f
        if ($null -eq $c) { $everything = $true; Write-Host "  $f -> every suite"; break }
        foreach ($x in $c) { $null = $want.Add($x) }
        if ($c.Count) { Write-Host "  $f -> $($c -join ', ')" }
    }
    if ($everything) { $Suite = $null }
    elseif (-not $want.Count) { Write-Host 'Nothing the suites cover changed since the recorded pass.'; exit 0 }
    else { $Suite = @($want) }
}
if ($Failed) {
    $last = if (Test-Path -LiteralPath $lastRunPath) { Get-Content -Raw -LiteralPath $lastRunPath | ConvertFrom-Json } else { $null }
    if (-not $last -or -not @($last.failed).Count) { Write-Host 'The last run had no failing suites.'; exit 0 }
    $Suite = @($last.failed)
    Write-Host "Again: $($Suite -join ', ')"
}
if ($Suite) { $files = $files | Where-Object { $Suite -contains $_.BaseName -or $Suite -contains ($_.BaseName -replace '^\d+-', '') } }
$all = -not $Suite

# Leftovers of an earlier run would hold the memory the suite's own machine needs.
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM') -DisableNameChecking 3>$null
$removedLeftovers = [System.Collections.Generic.List[string]]::new()
foreach ($vm in @(Get-VM | Where-Object { $_.Name -match "^($Template-[0-9a-f]{6}|e2e-[0-9a-f]{6}(-r)?)$" })) {
    Write-Host "removing leftover $($vm.Name)"
    $removedLeftovers.Add([regex]::Escape($vm.Name))
    if ($vm.State -ne 'Off') { Stop-VM -Name $vm.Name -TurnOff -Force -ErrorAction SilentlyContinue }
    if ($vm.Name -like "$Template-*") { Remove-GpuVMDisposable -Name $vm.Name -Confirm:$false -ErrorAction SilentlyContinue }
    else { Remove-GpuVM -Name $vm.Name -DeleteDisk -Confirm:$false -ErrorAction SilentlyContinue }
}

$ctx = [pscustomobject]@{ Exe = $Exe; Template = $Template; Out = $Out; Mcp = $null; Machine = $null }
try {
    $ctx.Mcp = Start-Mcp $Exe
    $appLog = Join-Path $env:LOCALAPPDATA 'GpuVM\app.log'
    $retried = [System.Collections.Generic.List[string]]::new()
    $timings = [System.Collections.Generic.List[string]]::new()
    $restarted = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $files) {
        # A suite that fails runs once more from the start (UI Automation and the machine's own pop-ups can trip a
        # check); only its second run counts, and the summary names it.
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            Write-Host "`n== $($f.BaseName)$(if ($attempt -gt 1) { ' (again)' })"
            # WebView2 sometimes stops exposing the page to UI Automation after a long run (only the window frame is
            # left); GpuVM is started again so the suite can read it. The machines keep running.
            if (-not (Test-E2EPageReadable)) {
                Write-Host '     the page is no longer readable through UI Automation: starting GpuVM again'
                $restarted.Add($f.BaseName)
                Restart-E2EApp $Exe
                $null = Wait-For { Test-E2EPageReadable } 40
            }
            $from = (Get-E2EResults).Count
            Set-E2ESuite $f.BaseName
            $took = [Diagnostics.Stopwatch]::StartNew()
            # GpuVM may still look for a leftover this run removed, a few seconds later.
            $script:ExpectedErrors = @(if ($removedLeftovers.Count) { "unable to find a virtual machine with name `"($($removedLeftovers -join '|'))`"" })
            $logAt = if (Test-Path -LiteralPath $appLog) { (Get-Item -LiteralPath $appLog).Length } else { 0 }
            . $f.FullName
            try { & (Get-Item "function:Test-Suite").ScriptBlock $ctx }
            catch { Check "$($f.BaseName) ran to the end" $false $_.Exception.Message }
            Remove-Item function:Test-Suite -ErrorAction SilentlyContinue
            # What the app showed or got back as an error while the suite ran (a suite lists the ones it causes on purpose).
            $errors = @(Get-AppLogErrors $appLog $logAt | Where-Object { $line = $_; -not @($script:ExpectedErrors | Where-Object { $line -match $_ }).Count })
            Check "$($f.BaseName): the app logged no errors" (-not $errors.Count) ($errors -join ' || ')
            # Each suite starts where a person would: the machine with its agent and GpuVM at Home.
            try { Reset-E2EApp $ctx } catch { Write-Host "     reset: $($_.Exception.Message)" }
            $timings.Add(("{0}{1} {2:N0} s" -f $f.BaseName, $(if ($attempt -gt 1) { ' (again)' }), $took.Elapsed.TotalSeconds))
            $so = Get-E2EResults
            $failedHere = @($so | Select-Object -Skip $from | Where-Object { -not $_.Ok }).Count
            if (-not $failedHere -or $attempt -eq 2) { break }
            $retried.Add($f.BaseName)
            $so.RemoveRange($from, $so.Count - $from)
        }
    }
}
finally {
    if ($ctx.Machine -and -not $KeepMachine) { try { $null = Invoke-Tool $ctx.Mcp 'destroy' @{ machine = $ctx.Machine; force = $true } } catch { } }
    if ($ctx.Mcp) { Stop-Mcp $ctx.Mcp }
}

$results = Get-E2EResults
$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "`n$($results.Count - $failed.Count) of $($results.Count) passed. Screenshots: $Out"
if ($retried -and $retried.Count) { Write-Host "Run again after a failure: $($retried -join ', ')" }
if ($timings -and $timings.Count) { Write-Host "Time per suite: $($timings -join ' | ')" }
if ($restarted -and $restarted.Count) { Write-Host "GpuVM started again (page unreadable) before: $($restarted -join ', ')" }
$failedSuites = @($results | Where-Object { -not $_.Ok } | ForEach-Object { $_.Suite } | Where-Object { $_ } | Sort-Object -Unique)
[ordered]@{ at = (Get-Date).ToUniversalTime().ToString('o'); suites = @($files | ForEach-Object BaseName); failed = $failedSuites } |
    ConvertTo-Json | Set-Content -Encoding utf8 $lastRunPath
if (-not $failed.Count) {
    $commit = (git -C $repo rev-parse HEAD).Trim()
    $exeHash = (Get-FileHash -LiteralPath $Exe).Hash
    if (git -C $repo status --porcelain) { Write-Host 'Not recorded for the release: uncommitted changes.' }
    elseif ($all) {
        [ordered]@{ commit = $commit; exe = $exeHash; at = (Get-Date).ToUniversalTime().ToString('o'); checks = $results.Count } |
            ConvertTo-Json | Set-Content -Encoding utf8 $stampPath
        Write-Host "Recorded for the release: commit $commit."
    }
    elseif ($stamp -and $stamp.commit -ne $commit) {
        # Carried forward only when the app is the one the full pass checked and every changed suite ran again.
        $since = @(git -C $repo diff --name-only "$($stamp.commit)..HEAD" | Where-Object { $_ })
        $ran = @($files | ForEach-Object BaseName)
        $app = @($since | Where-Object { Test-AppCode $_ })
        $missing = @($since | ForEach-Object { $c = Get-CoveringSuites $_; if ($null -eq $c) { '*' } else { $c } } | Where-Object { $_ -eq '*' -or $ran -notcontains $_ } | Sort-Object -Unique)
        if ($app.Count -or $exeHash -ne $stamp.exe) { Write-Host "Not carried to $commit`: the app changed since the recorded pass ($($app.Count) file(s)); a full run records it." }
        elseif ($missing.Count) { Write-Host "Not carried to $commit`: these suites also need to run again: $($missing -join ', ')." }
        else {
            [ordered]@{ commit = $commit; exe = $exeHash; at = (Get-Date).ToUniversalTime().ToString('o'); checks = $stamp.checks; carriedFrom = $stamp.commit; suitesAgain = $ran } |
                ConvertTo-Json | Set-Content -Encoding utf8 $stampPath
            Write-Host "Recorded for the release: commit $commit (the full pass of $($stamp.commit.Substring(0, 7)) plus $($ran -join ', ') again)."
        }
    }
}
exit [int]($failed.Count -gt 0)
