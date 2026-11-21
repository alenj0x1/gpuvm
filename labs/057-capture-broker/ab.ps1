# Lab 057: interleaved A/B of WGC helper builds with flashes.ps1 (round-robin, so drift in the guest hits both).
# -Helpers label=path,... Run elevated. Prints one line per run; JSON per run in out\.
param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$Helpers, [int]$Rounds = 3, [int]$Seconds = 60, [string]$Load = 'label')
$lab = Join-Path $PSScriptRoot 'flashes.ps1'
for ($r = 1; $r -le $Rounds; $r++) {
    foreach ($h in $Helpers) {
        $label, $path = $h -split '=', 2
        $res = pwsh -NoProfile -Command "& '$lab' -Name '$Name' -Label '$label-r$r' -Helper '$path' -Seconds $Seconds -Load $Load 6>`$null | ConvertTo-Json -Compress" 2>$null | Select-Object -Last 1
        "$(Get-Date -Format HH:mm:ss) $label r$r $res"
    }
}
