# Waits (polling every 30 s, at most -MaxMinutes) until the shared lab lock C:\GpuVM\.lab-lock is free and takes it
# exclusively (CreateNew: fails if another session took it first) with this session's name and task. Exit 0 when held.
param([Parameter(Mandatory)][string]$What, [int]$MaxMinutes = 120)
$file = 'C:\GpuVM\.lab-lock'
$end = (Get-Date).AddMinutes($MaxMinutes)
while ((Get-Date) -lt $end) {
    try {
        $fs = [IO.File]::Open($file, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $bytes = [Text.Encoding]::UTF8.GetBytes("admin-dock | $What | $((Get-Date).ToString('o'))")
        $fs.Write($bytes, 0, $bytes.Length); $fs.Close()
        "lock taken at $(Get-Date -Format HH:mm:ss)"
        exit 0
    }
    catch [IO.IOException] { Start-Sleep -Seconds 30 }
}
"gave up after $MaxMinutes min: $(Get-Content $file -ErrorAction SilentlyContinue)"
exit 1
