# Runs at logon in the HCS guest (HKLM Run key written offline by stream.ps1): tells the host its address over a
# Hyper-V socket, shows the moving bar of tools/latency/motion-target.ps1, and keeps the socket open for commands
# ("mode <w> <h> <hz>": sets the display with GpuVM's guest\set-resolution.ps1, as GpuVM does through PowerShell Direct).
$dir = 'C:\GpuVMLab065'
$log = Join-Path $dir 'stream-guest.log'
function Note([string]$m) { Add-Content $log "$(Get-Date -Format o) $m" }
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $dir 'motion-target.ps1'), '-Minutes', '180'
try {
    $ip = $null; $w = [Diagnostics.Stopwatch]::StartNew()
    while ($w.Elapsed.TotalSeconds -lt 120 -and -not $ip) {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.AddressState -eq 'Preferred' } | Select-Object -First 1 -ExpandProperty IPAddress
        if (-not $ip) { Start-Sleep -Milliseconds 500 }
    }
    Note "ip $ip after $([math]::Round($w.Elapsed.TotalSeconds,1)) s"
    Add-Type -Path (Join-Path $dir 'hvsock.cs')
    $s = [HvSock]::Dial([HvSock]::Parent, [guid](Get-Content (Join-Path $dir 'service.txt') -Raw).Trim())
    [HvSock]::SendLine($s, "ip=$ip")
    while ($true) {
        $cmd = [HvSock]::ReadLine($s, 86400000)
        if (-not $cmd) { break }
        if ($cmd -match '^mode (\d+) (\d+) (\d+)$') {
            $out = Join-Path $dir 'resolution.json'; Remove-Item $out -ErrorAction SilentlyContinue
            & (Join-Path $dir 'set-resolution.ps1') -Width $Matches[1] -Height $Matches[2] -Refresh $Matches[3] -Out $out
            $reply = if (Test-Path $out) { (Get-Content $out -Raw | ConvertFrom-Json | ConvertTo-Json -Compress -Depth 4) } else { '{"ok":false}' }
            Note "$cmd -> $reply"
            [HvSock]::SendLine($s, $reply)
        } else { [HvSock]::SendLine($s, '{"ok":false,"error":"unknown"}') }
    }
} catch { Note "error: $_" }
