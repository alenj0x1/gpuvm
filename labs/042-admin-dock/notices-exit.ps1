# Lab 042, part 6: notices-only mode ends by itself when the last watched machine stops. In one lock turn: installs
# the build, waits for GpuVM to be up, quits it the way the window's close button does (WM_CLOSE to the main window)
# so it stays in notices-only mode, checks that only gpuvm.exe is left, and hands the lock over. Then, without the
# lock (only watching), it records when -Name stops and when gpuvm.exe exits, for up to -WatchMinutes.
# The lock is taken only when the queue (C:\GpuVM\.lab-queue) has this session first; its line is removed then.
# Run elevated: pwsh -File labs/042-admin-dock/notices-exit.ps1 -Name win-gpu
param(
    [string]$Name = 'win-gpu',
    [string]$Setup = (Join-Path $PSScriptRoot '..\..\app\src-tauri\target\release\bundle\nsis\GpuVM_0.9.0_x64-setup.exe'),
    [int]$WatchMinutes = 120,
    [string]$Out = (Join-Path $PSScriptRoot "out\notices-exit-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt")
)
$ErrorActionPreference = 'Stop'
$lock = 'C:\GpuVM\.lab-lock'
$queue = 'C:\GpuVM\.lab-queue'
function Log([string]$Text) { $line = "$(Get-Date -Format 'HH:mm:ss.fff') $Text"; $line; Add-Content -LiteralPath $Out $line }
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null

# 1. Our turn: first in the queue and the lock free (polled every 30 s).
while ($true) {
    $first = if (Test-Path $queue) { (Get-Content $queue | Where-Object { $_.Trim() } | Select-Object -First 1) } else { 'admin-dock' }
    if ($first -eq 'admin-dock') {
        try {
            $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $bytes = [Text.Encoding]::UTF8.GetBytes("admin-dock | lab 042: instalo mi build y dejo GpuVM en modo solo avisos (~10 min) | $((Get-Date).ToString('o'))")
            $fs.Write($bytes, 0, $bytes.Length); $fs.Close()
            break
        }
        catch [IO.IOException] { }
    }
    Start-Sleep -Seconds 30
}
if (Test-Path $queue) { Set-Content $queue (@(Get-Content $queue | Where-Object { $_.Trim() -and $_.Trim() -ne 'admin-dock' })) }
Log 'lock taken'

try {
    # 2. Install and open GpuVM (the installer starts it).
    & (Join-Path $PSScriptRoot '..\039-viewer-bridge\install-build.ps1') -Setup $Setup | ForEach-Object { Log $_ }
    $app = $null
    for ($i = 0; $i -lt 60 -and -not $app; $i++) { Start-Sleep -Seconds 1; $app = Get-Process gpuvm -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $app) { throw 'GpuVM no arrancó.' }
    Start-Sleep -Seconds 10
    Add-Type -Namespace Lab042 -Name Exit -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(System.IntPtr h, out int pid);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, System.IntPtr l);
public struct RECT { public int Left, Top, Right, Bottom; }
public static System.IntPtr Main(int pid) { System.IntPtr best = System.IntPtr.Zero; long area = 0;
  EnumWindows((h,l)=>{ int p; GetWindowThreadProcessId(h,out p); RECT r; if (p==pid && IsWindowVisible(h) && GetWindowRect(h,out r)) { long a=(long)(r.Right-r.Left)*(r.Bottom-r.Top); if (a>area) { area=a; best=h; } } return true; }, System.IntPtr.Zero); return best; }
'@
    # 3. Quit like the close button: with the machine on it must stay in notices-only mode.
    $main = [Lab042.Exit]::Main($app.Id)
    [void][Lab042.Exit]::PostMessage($main, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
    Start-Sleep -Seconds 5
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($app.Id)")
    Log "after quit: gpuvm alive=$([bool](Get-Process -Id $app.Id -ErrorAction SilentlyContinue)) children=$($children.Count) ($($children.Name -join ','))"
}
finally {
    if ((Get-Content $lock -ErrorAction SilentlyContinue) -like 'admin-dock*') { Remove-Item $lock; Log 'lock released' }
}

# 4. Watch only: when the machine stops and when GpuVM exits.
$stoppedAt = $null
$end = (Get-Date).AddMinutes($WatchMinutes)
while ((Get-Date) -lt $end) {
    $state = (Get-VM -Name $Name).State
    if (-not $stoppedAt -and $state -ne 'Running') { $stoppedAt = Get-Date; Log "$Name is $state" }
    if (-not (Get-Process -Id $app.Id -ErrorAction SilentlyContinue)) {
        Log "gpuvm.exe exited$(if ($stoppedAt) { ' ' + [math]::Round(((Get-Date) - $stoppedAt).TotalSeconds, 1) + ' s after the machine stopped' } else { ' while the machine was still on (unexpected)' })"
        return
    }
    Start-Sleep -Milliseconds 500
}
Log 'gave up watching'
