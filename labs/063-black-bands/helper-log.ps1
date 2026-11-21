# Lab 063: the newest WGC helper log's lab063 lines (and capture diagnostics), plus its verification dumps converted
# to PNG in out\<Label>\. Run elevated.
param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Label, [int]$Tail = 30)
. (Join-Path $PSScriptRoot 'common.ps1')
$cred = Get-Lab063Cred $Name
$out = Join-Path $PSScriptRoot "out\$Label"
New-Item -ItemType Directory -Force $out | Out-Null
$s = New-PSSession -VMName $Name -Credential $cred
try {
    $info = Invoke-Command -Session $s {
        $user = (Get-CimInstance Win32_ComputerSystem).UserName.Split('\')[-1]
        $dir = "C:\Users\$user\AppData\Roaming\Sunshine\wgc-helper"
        $f = Get-ChildItem $dir -Filter *.log | Sort-Object Name | Select-Object -Last 1
        [pscustomobject]@{
            log   = $f.FullName
            lines = @(Get-Content $f.FullName | Where-Object { $_ -match 'lab063|capture_fps|copy wait' } | ForEach-Object { $_.Substring(0, [Math]::Min(260, $_.Length)) })
            dumps = @(Get-ChildItem $dir -Filter 'lab063-*.bgra' | Sort-Object LastWriteTime | ForEach-Object FullName)
        }
    }
    $info.lines | Set-Content (Join-Path $out 'helper-lines.log')
    foreach ($d in $info.dumps) {
        $local = Join-Path $out (Split-Path $d -Leaf)
        Copy-Item -FromSession $s -Path $d -Destination $local -Force
        if ((Split-Path $d -Leaf) -match '-(\d+)x(\d+)\.bgra$') {
            & ffmpeg -v error -f rawvideo -pix_fmt bgra -s "$($Matches[1])x$($Matches[2])" -i $local -frames:v 1 -y ($local -replace '\.bgra$', '.png')
            Remove-Item $local
        }
    }
    if ($info.dumps) { Invoke-Command -Session $s -ArgumentList (, $info.dumps) { param($d) $d | ForEach-Object { Remove-Item $_ -Force -ErrorAction SilentlyContinue } } }
    $info.lines | Select-Object -Last $Tail
    "dumps: $($info.dumps.Count) -> $out"
}
finally { Remove-PSSession $s }
