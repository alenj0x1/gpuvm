# Lab 039: the viewer inside the GpuVM window, without the app's code path. Plays the app's side of the pipe like
# bridge-smoke.ps1, streams a real VM with --gpuvm-embed over GpuVM's window and reveals the picture a moment after
# the first frame (as the app does after its zoom). Run screen.ps1 film alongside to see whether anything shows over
# the app before the reveal.
param(
    [Parameter(Mandatory)][string]$Address,
    [string]$Viewer = (Join-Path $PSScriptRoot '..\..\viewer\GpuVMViewer.exe'),
    [int]$RevealAfterMs = 1500,
    [int]$StaySec = 4
)
$ErrorActionPreference = 'Stop'
Add-Type -Namespace Lab -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int c);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
public static void RestoreAll(int pid) { EnumWindows((h, l) => { int p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h) && IsIconic(h)) ShowWindow(h, 9); return true; }, System.IntPtr.Zero); }
[DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(System.IntPtr h, out int pid);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, System.IntPtr l);
public static System.IntPtr Largest(int pid) {
    System.IntPtr best = System.IntPtr.Zero; long area = 0;
    EnumWindows((h, l) => { int p; GetWindowThreadProcessId(h, out p); RECT r;
        if (p == pid && IsWindowVisible(h) && GetWindowRect(h, out r)) { long a = (long)(r.Right - r.Left) * (r.Bottom - r.Top); if (a > area) { area = a; best = h; } }
        return true; }, System.IntPtr.Zero);
    return best;
}
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
public struct RECT { public int Left, Top, Right, Bottom; }
public struct POINT { public int X, Y; }
'@
[Lab.Win]::SetProcessDPIAware() | Out-Null
$app = Get-Process gpuvm | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
# The app's main window: its largest visible window (the side panel is another window of the same process).
[Lab.Win]::RestoreAll($app.Id); Start-Sleep -Milliseconds 500
$h = [Lab.Win]::Largest($app.Id)
[Lab.Win]::SetForegroundWindow($h) | Out-Null; Start-Sleep -Milliseconds 300
# GpuVM's window has no border of its own: its window rectangle is its client area.
$r = New-Object Lab.Win+RECT; [Lab.Win]::GetWindowRect($h, [ref]$r) | Out-Null
$top = 40  # title bar at 100 % scale
$embed = "$([int64]$h),$($r.Left),$($r.Top + $top),$($r.Right - $r.Left),$($r.Bottom - $r.Top - $top)"
Write-Host "embed $embed"

$bytes = [byte[]]::new(16); [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$pipeName = 'gpuvm-viewer-' + (-join ($bytes | ForEach-Object { $_.ToString('x2') }))
$tb = [byte[]]::new(32); [Security.Cryptography.RandomNumberGenerator]::Fill($tb)
$token = -join ($tb | ForEach-Object { $_.ToString('x2') })
$security = [IO.Pipes.PipeSecurity]::new()
$security.AddAccessRule([IO.Pipes.PipeAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'Allow'))
$server = [IO.Pipes.NamedPipeServerStreamAcl]::Create($pipeName, 'InOut', 1, 'Byte', 'Asynchronous', 65536, 65536, $security)

$psi = [Diagnostics.ProcessStartInfo]::new((Resolve-Path $Viewer).Path)
foreach ($a in @('stream', $Address, 'Desktop', '--display-mode', 'windowed', '--gpuvm-embed', $embed, '--gpuvm-pipe', "\\.\pipe\$pipeName", '--gpuvm-token-env', 'GPUVM_VIEWER_TOKEN')) { $psi.ArgumentList.Add($a) }
$psi.Environment['GPUVM_VIEWER_TOKEN'] = $token
$psi.UseShellExecute = $false
$started = Get-Date
$process = [Diagnostics.Process]::Start($psi)
if (-not $server.WaitForConnectionAsync().Wait(20000)) { throw 'no connection' }
$reader = [IO.StreamReader]::new($server); $writer = [IO.StreamWriter]::new($server); $writer.AutoFlush = $true
$null = $reader.ReadLine()
$revealed = $false; $deadline = (Get-Date).AddSeconds(60)
$t = $null
while ((Get-Date) -lt $deadline) {
    if (-not $t) { $t = $reader.ReadLineAsync() }
    if (-not $t.Wait(500)) { continue }
    $line = $t.Result; $t = $null
    if ($null -eq $line) { break }
    $ms = [int]((Get-Date) - $started).TotalMilliseconds
    if ($line -notmatch '"stats"') { Write-Host ("{0,6} ms  {1}" -f $ms, $line) }
    if ($line -match '"first-frame"' -and -not $revealed) {
        Start-Sleep -Milliseconds $RevealAfterMs
        $writer.WriteLine('{"type":"reveal","fullscreen":false}')
        Write-Host ("{0,6} ms  reveal sent" -f [int]((Get-Date) - $started).TotalMilliseconds)
        $revealed = $true
        Start-Sleep -Seconds $StaySec
        $writer.WriteLine('{"type":"quit"}')
    }
}
$process.WaitForExit(10000) | Out-Null
$server.Dispose()
