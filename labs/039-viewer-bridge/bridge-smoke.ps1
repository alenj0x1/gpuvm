# Lab 039 smoke test: the GpuVM viewer's private pipe without a VM.
# Plays the app's side: creates the pipe (current user only), starts the viewer with a one-time token in its
# environment, checks the hello, and prints every message until the viewer exits. Pointed at an address with no
# Sunshine, the viewer must report the failure over the pipe and exit on its own (its Qt window stays hidden).
param(
    [string]$Viewer = (Join-Path $PSScriptRoot '..\..\viewer\GpuVMViewer.exe'),
    [string]$Address = '127.0.0.1',
    [int]$TimeoutSec = 60
)
$ErrorActionPreference = 'Stop'
$Viewer = (Resolve-Path $Viewer).Path

$bytes = [byte[]]::new(16); [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$suffix = -join ($bytes | ForEach-Object { $_.ToString('x2') })
$pipeName = "gpuvm-viewer-$suffix"
$tokenBytes = [byte[]]::new(32); [Security.Cryptography.RandomNumberGenerator]::Fill($tokenBytes)
$token = -join ($tokenBytes | ForEach-Object { $_.ToString('x2') })

$me = [Security.Principal.WindowsIdentity]::GetCurrent().User
$security = [IO.Pipes.PipeSecurity]::new()
$security.AddAccessRule([IO.Pipes.PipeAccessRule]::new($me, 'FullControl', 'Allow'))
$server = [IO.Pipes.NamedPipeServerStreamAcl]::Create($pipeName, 'InOut', 1, 'Byte', 'Asynchronous', 65536, 65536, $security)

$psi = [Diagnostics.ProcessStartInfo]::new($Viewer)
foreach ($a in @('stream', $Address, 'Desktop', '--gpuvm-pipe', "\\.\pipe\$pipeName", '--gpuvm-token-env', 'GPUVM_VIEWER_TOKEN')) { $psi.ArgumentList.Add($a) }
$psi.Environment['GPUVM_VIEWER_TOKEN'] = $token
$psi.UseShellExecute = $false
$started = Get-Date
$process = [Diagnostics.Process]::Start($psi)
Write-Host "viewer pid $($process.Id)"

$wait = $server.WaitForConnectionAsync()
if (-not $wait.Wait(20000)) { throw 'The viewer did not connect in 20 s.' }
$connectMs = [int]((Get-Date) - $started).TotalMilliseconds
$reader = [IO.StreamReader]::new($server)
$hello = $reader.ReadLine() | ConvertFrom-Json
$tokenOk = $hello.type -eq 'hello' -and $hello.token -eq $token
Write-Host "connected in $connectMs ms; hello ok: $tokenOk; pid in hello: $($hello.pid)"

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$messages = @()
while ((Get-Date) -lt $deadline) {
    $line = $reader.ReadLineAsync()
    if (-not $line.Wait([int][Math]::Max(1, ($deadline - (Get-Date)).TotalMilliseconds))) { break }
    if ($null -eq $line.Result) { break }
    $elapsed = [int]((Get-Date) - $started).TotalMilliseconds
    Write-Host ("{0,6} ms  {1}" -f $elapsed, $line.Result)
    $messages += $line.Result
}
$exited = $process.WaitForExit(10000)
$windows = if (-not $exited) { (Get-Process -Id $process.Id).MainWindowHandle } else { 0 }
Write-Host "viewer exited: $exited (code $(if ($exited) { $process.ExitCode } else { 'running' })); messages: $($messages.Count)"
if (-not $exited) { Stop-Process -Id $process.Id -Force }
$server.Dispose()
