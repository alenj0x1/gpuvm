# How many frames the VM's compositor (DWM) actually composes and shows per second, from its own counters
# (DwmGetCompositionTimingInfo), without reading the screen. Run as administrator on the host; the sampler runs in the
# VM's desktop session. With -Target gdi or gpu it first starts the moving bar (motion-target.ps1 or the Edge page of
# labs/021-stream-smoothness/gdi-vs-gpu.ps1), so the desktop changes all the time.
#   tools/latency/guest-dwm.ps1 -Name win-gpu [-Seconds 5]
param([Parameter(Mandatory)][string]$Name, [double]$Seconds = 5)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$vm = Get-LatencyVM -Name $Name
$sampler = @'
$ErrorActionPreference = 'Stop'
try {
    Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class Dwm {
    [StructLayout(LayoutKind.Sequential, Pack = 1)] public struct UNSIGNED_RATIO { public uint uiNumerator, uiDenominator; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] public struct TIMING_INFO {
        public uint cbSize; public UNSIGNED_RATIO rateRefresh; public ulong qpcRefreshPeriod; public UNSIGNED_RATIO rateCompose;
        public ulong qpcVBlank, cRefresh; public uint cDXRefresh; public ulong qpcCompose, cFrame; public uint cDXPresent;
        public ulong cRefreshFrame, cFrameSubmitted; public uint cDXPresentSubmitted; public ulong cFrameConfirmed;
        public uint cDXPresentConfirmed; public ulong cRefreshConfirmed; public uint cDXRefreshConfirmed;
        public ulong cFramesLate; public uint cFramesOutstanding; public ulong cFrameDisplayed, qpcFrameDisplayed, cRefreshFrameDisplayed,
            cFrameComplete, qpcFrameComplete, cFramePending, qpcFramePending, cFramesDisplayed, cFramesComplete, cFramesPending,
            cFramesAvailable, cFramesDropped, cFramesMissed, cRefreshNextDisplayed, cRefreshNextPresented, cRefreshesDisplayed,
            cRefreshesPresented, cRefreshStarted, cPixelsReceived, cPixelsDrawn, cBuffersEmpty;
    }
    [DllImport("dwmapi.dll")] public static extern int DwmGetCompositionTimingInfo(IntPtr hwnd, ref TIMING_INFO info);
    public static TIMING_INFO Get() { var t = new TIMING_INFO(); t.cbSize = (uint)Marshal.SizeOf(typeof(TIMING_INFO)); int hr = DwmGetCompositionTimingInfo(IntPtr.Zero, ref t); if (hr != 0) throw new Exception("hr " + hr); return t; }
}
"@
    $a = [Dwm]::Get(); $w = [Diagnostics.Stopwatch]::StartNew(); Start-Sleep -Milliseconds ([int](SECONDS * 1000)); $b = [Dwm]::Get(); $s = $w.Elapsed.TotalSeconds
    @{ seconds = $s; refreshHz = [math]::Round($b.rateRefresh.uiNumerator / [math]::Max(1, $b.rateRefresh.uiDenominator), 1);
       composedPerSec = [math]::Round(($b.cFrame - $a.cFrame) / $s, 1); refreshesPerSec = [math]::Round(($b.cRefresh - $a.cRefresh) / $s, 1);
       dxPresentsPerSec = [math]::Round(($b.cDXPresent - $a.cDXPresent) / $s, 1) } | ConvertTo-Json -Compress | Set-Content C:\GpuVM\dwm.json
} catch { @{ error = "$_" } | ConvertTo-Json -Compress | Set-Content C:\GpuVM\dwm.json }
'@
$sampler = $sampler.Replace('SECONDS', [string]$Seconds)
Invoke-Command -VMName $Name -Credential $vm.Guest -ArgumentList $sampler -ScriptBlock {
    param($code)
    New-Item -ItemType Directory -Force C:\GpuVM | Out-Null
    Set-Content C:\GpuVM\dwm.ps1 $code; Remove-Item C:\GpuVM\dwm.json -ErrorAction SilentlyContinue
    $user = (Get-CimInstance Win32_ComputerSystem).UserName
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\GpuVM\dwm.ps1'
    Register-ScheduledTask -TaskName GpuVM-Dwm -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
    try {
        Start-ScheduledTask GpuVM-Dwm
        $deadline = (Get-Date).AddSeconds(60)
        while (-not (Test-Path C:\GpuVM\dwm.json) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    } finally { Unregister-ScheduledTask GpuVM-Dwm -Confirm:$false -ErrorAction SilentlyContinue }
    $r = if (Test-Path C:\GpuVM\dwm.json) { Get-Content C:\GpuVM\dwm.json -Raw } else { '{"error":"no answer"}' }
    Remove-Item C:\GpuVM\dwm.ps1, C:\GpuVM\dwm.json -ErrorAction SilentlyContinue
    $r
}
