# Lab 024: what makes Sunshine's DDX capture restart at the start of each session (lab 023), so DDX (which shows
# Windows administrator prompts) can start as fast as WGC. Runs lab 023's reconnect measurement with DDX, once per
# candidate cause, and compares Sunshine's own time to the first real frame ("Executing" -> "Capture format").
# Run elevated, in the signed-in user's session:
#   pwsh -File labs/024-ddx-restarts/run.ps1 -Name win10
param(
    [string]$Name = 'win10',
    [int]$Count = 8,
    [string[]]$Only
)
$ErrorActionPreference = 'Stop'
$lab023 = Join-Path $PSScriptRoot '..\023-reconnect-black\run.ps1'
$out = Join-Path $PSScriptRoot "out\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$cases = @(
    # The VM shows a full-screen window (as a game in borderless does): DDX may lose the capture on full-screen changes.
    @{ Label = 'fullscreen'; Target = 'fullscreen' }
    # The same picture in a normal window over 70 % of the screen.
    @{ Label = 'windowed'; Target = 'windowed' }
    # Nothing on screen: the plain desktop.
    @{ Label = 'idle'; Target = 'none' }
) | Where-Object { -not $Only -or $_.Label -in $Only }
foreach ($case in $cases) {
    "=== $($case.Label)" | Write-Host
    & $lab023 -Name $Name -Count $Count -Capture ddx -Target $case.Target -Label $case.Label -OutDir (Join-Path $out $case.Label)
}
foreach ($case in $cases) {
    $r = Get-Content (Join-Path $out "$($case.Label)\result.json") -Raw | ConvertFrom-Json
    $s = @($r.sessions | ForEach-Object { $_.sunshineSec })
    "$($case.Label): sunshine first real frame $($s -join ', ') s (median $($r.sunshineMedianSec)); picture median $($r.pictureMedianSec) s, never $($r.neverShown)" | Write-Host
}
"saved $out" | Write-Host
