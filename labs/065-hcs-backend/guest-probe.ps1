# Runs inside the guest at logon (HKLM Run key written offline by run.ps1), records what the guest sees and shuts down.
$dir = 'C:\GpuVMLab065'
$r = [ordered]@{ started = (Get-Date).ToString('o') }
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $r.boot = $os.LastBootUpTime.ToString('o')
    $r.secondsBootToLogonScript = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalSeconds, 1)
    $r.edition = $os.Caption
    $r.user = "$env:USERDOMAIN\$env:USERNAME"
    $r.video = @(Get-CimInstance Win32_VideoController | ForEach-Object {
            [ordered]@{ name = $_.Name; status = $_.Status; driver = $_.DriverVersion; pnp = $_.PNPDeviceID; mode = "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)@$($_.CurrentRefreshRate)" } })
    $r.displayDevices = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | ForEach-Object {
            [ordered]@{ name = $_.FriendlyName; status = "$($_.Status)"; problem = "$($_.Problem)"; id = $_.InstanceId } })
    $smi = @('C:\Windows\System32\nvidia-smi.exe') + @(Get-ChildItem 'C:\Windows\System32\HostDriverStore\FileRepository' -Recurse -Filter nvidia-smi.exe -ErrorAction SilentlyContinue | ForEach-Object FullName) |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($smi) {
        $r.nvidiaSmiPath = $smi
        $r.nvidiaSmi = (& $smi --query-gpu=name,driver_version,memory.total,utilization.gpu --format=csv,noheader 2>&1 | Out-String).Trim()
    }
    $dx = Join-Path $dir 'dxdiag.txt'
    $p = Start-Process dxdiag.exe -ArgumentList "/t $dx" -PassThru
    if ($p.WaitForExit(90000) -and (Test-Path $dx)) {
        $t = Get-Content $dx
        $r.dxdiag = @($t | Where-Object { $_ -match '^\s*(Card name|Driver Model|Feature Levels|DDI Version|Display Memory|Dedicated Memory|Shared Memory|Current Mode|Monitor Name|DirectX Version)\s*:' } | ForEach-Object { $_.Trim() })
    } else { $r.dxdiag = 'timeout'; try { $p.Kill() } catch {} }
    $r.integrationServices = @(Get-Service vmic* -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ name = $_.Name; status = "$($_.Status)" } })
    $kvp = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters'
    $r.kvpHostParameters = if (Test-Path $kvp) { @((Get-Item $kvp).Property) } else { @() }
    $r.services = @(Get-Service SunshineService, 'GpuVM Agent', GpuVMAgent -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ name = $_.Name; status = "$($_.Status)" } })
    $ip = $null; $w = [Diagnostics.Stopwatch]::StartNew()
    while ($w.Elapsed.TotalSeconds -lt 90 -and -not $ip) {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.AddressState -eq 'Preferred' } | Select-Object -First 1 -ExpandProperty IPAddress
        if (-not $ip) { Start-Sleep -Milliseconds 500 }
    }
    $r.ipv4 = $ip; $r.secondsToIp = [math]::Round($w.Elapsed.TotalSeconds, 1)
    $r.network = @(Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ name = $_.Name; desc = $_.InterfaceDescription; status = "$($_.Status)"; mac = $_.MacAddress } })
    if ($ip) {
        $r.gateway = (Get-NetRoute -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
        $r.internet = try { $c = [Net.Sockets.TcpClient]::new(); [bool]($c.ConnectAsync('www.microsoft.com', 443).Wait(5000) -and $c.Connected) } catch { "error: $_" }
    }
    try {
        Add-Type -Path (Join-Path $dir 'hvsock.cs')
        $svc = [guid](Get-Content (Join-Path $dir 'service.txt') -Raw).Trim()
        $w = [Diagnostics.Stopwatch]::StartNew()
        $s = [HvSock]::Dial([HvSock]::Parent, $svc)
        $r.hvsockConnectMs = [math]::Round($w.Elapsed.TotalMilliseconds, 1)
        [HvSock]::SendLine($s, "ip=$ip")
        $r.hvsockHostReply = [HvSock]::ReadLine($s, 30000)
        [HvSock]::SendLine($s, 'bye'); $s.Close()
        $r.hvsock = 'ok'
    } catch { $r.hvsock = "error: $($_.Exception.ToString())" }
} catch { $r.error = "$_" }
finally {
    $r.finished = (Get-Date).ToString('o')
    $r | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $dir 'result.json') -Encoding UTF8
    shutdown.exe /s /t 3 /f
}
