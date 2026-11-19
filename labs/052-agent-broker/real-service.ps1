# Lab 052, real service: puts this branch's gpuvm-host.exe (release) in place of the installed one for a short run,
# then puts the original back. Under the shared lab lock the whole time (the broker holds the Hyper-V socket name, and
# the guest agent's lab needs it too). Checks: the installer registers the service id, the real service listens,
# latency over loopback with the release build, and how fast agents come back after the service restarts.
# Run elevated. The GpuVM app keeps working (same pipe protocol); VMs are not touched.
param([int]$Restarts = 3, [string]$Session = 'agent-broker', [string[]]$Parts = @('latency', 'parallel', 'attacks'))
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$installed = Join-Path $env:ProgramFiles 'GpuVM\gpuvm-host.exe'
$backup = 'C:\GpuVM\lab052\gpuvm-host.installed.exe'
$out = Join-Path $PSScriptRoot 'out'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
& cargo build --release --manifest-path (Join-Path $root 'app\host\Cargo.toml') 2>&1 | Select-Object -Last 1
if ($LASTEXITCODE) { throw 'build failed' }
& (Join-Path $root 'labs\042-admin-dock\take-lock.ps1') -What 'lab 052: real GpuVM service with the agent broker (listens on the agent channel)' -Me $Session -MaxMinutes 120
if ($LASTEXITCODE) { throw 'no lock' }
$result = [ordered]@{}
try {
    & (Join-Path $PSScriptRoot 'broker.ps1') -Stop | Out-Null
    New-Item -ItemType Directory -Force (Split-Path $backup) | Out-Null
    Copy-Item $installed $backup -Force
    Stop-Service GpuVM -ErrorAction SilentlyContinue
    (Get-Service GpuVM).WaitForStatus('Stopped', '00:01:00')
    Copy-Item (Join-Path $root 'app\host\target\release\gpuvm-host.exe') $installed -Force
    # What the installer runs: registers (updates) the service and the agent channel's service id.
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices\{94aca5ef-a5b6-45a9-8c15-c7724a63f3da}'
    if (Test-Path $key) { Remove-Item $key }
    & $installed install
    $result['installRegistersServiceId'] = (Get-ItemProperty $key -ErrorAction SilentlyContinue).ElementName
    Start-Service GpuVM
    Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $(try { (Get-GpuVMAgentBroker).listening } catch { $false }) -and $sw.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 100 }
    $result['listeningAfterStartMs'] = [math]::Round($sw.Elapsed.TotalMilliseconds)

    # Release build over loopback (the lab's loopback machine and stub).
    & (Join-Path $PSScriptRoot 'loopback.ps1') | Out-Null
    $env:STUB052_TARGET = 'loopback'
    pwsh -NoProfile -Command "& '$PSScriptRoot\run.ps1' -Loopback -Parts $(($Parts | ForEach-Object { "'$_'" }) -join ',') -Rounds 2" 2>&1 | Where-Object { $_ -notmatch '^saved' }

    # Service restarts: how long until the (loopback) agent is connected again.
    $loopDir = 'C:\GpuVM\lab052\loopback'
    $stub = Join-Path $PSScriptRoot 'stub\target\release\stub052.exe'
    $p = Start-Process $stub -ArgumentList 'run', '--secret', "$loopDir\secret.raw", '--vm-id', 'e0e16197-dd56-4a10-9195-5ee7a155a838' -PassThru -WindowStyle Hidden
    try {
        $rows = for ($i = 0; $i -lt $Restarts; $i++) {
            Start-Sleep -Seconds 2
            $sw = [Diagnostics.Stopwatch]::StartNew()
            Restart-Service GpuVM
            $up = $sw.Elapsed.TotalMilliseconds
            $ready = $null
            while ($sw.Elapsed.TotalSeconds -lt 30) {
                $a = try { @(Get-GpuVMAgent -Name loopback052)[0] } catch { $null }
                if ($a -and $a.state -eq 'ready') { $ready = $sw.Elapsed.TotalMilliseconds; break }
                Start-Sleep -Milliseconds 50
            }
            [ordered]@{ restartMs = [math]::Round($up); agentReadyMs = if ($ready) { [math]::Round($ready) } }
        }
        $result['serviceRestarts'] = @($rows)
    }
    finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}
finally {
    # The installed service goes back exactly as it was.
    Stop-Service GpuVM -ErrorAction SilentlyContinue
    (Get-Service GpuVM).WaitForStatus('Stopped', '00:01:00')
    if (Test-Path $backup) { Copy-Item $backup $installed -Force }
    Start-Service GpuVM -ErrorAction SilentlyContinue
    & (Join-Path $PSScriptRoot 'loopback.ps1') -Remove | Out-Null
    Remove-Item 'C:\GpuVM\.lab-lock' -Force -ErrorAction SilentlyContinue
    "lock released $(Get-Date -Format HH:mm:ss)"
    $result | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out "real-service-$stamp.json") -Encoding utf8
    $result | ConvertTo-Json -Depth 5 -Compress
}
