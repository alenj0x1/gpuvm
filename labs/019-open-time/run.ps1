# Lab 019: where the time goes when a VM is opened, and how long the picture stays black.
# Runs Connect-GpuVM as the app does, timing each step inside it, then keeps watching after it returns:
#   window  Moonlight shows its window
#   stream  Moonlight's log says "Video stream is" (the first frame arrived)
#   light   the Moonlight window stops being black (mean brightness of a 64x36 sample above a threshold)
# Cold runs shut the VM down first; warm runs open it while it is already on. Closes Moonlight between runs.
# Run elevated, in the signed-in user's session (Moonlight's window and log are theirs):
#   pwsh -File labs/019-open-time/run.ps1 -Name win10 -Cold 2 -Warm 3
param(
    [string]$Name = 'win10',
    [int]$Cold = 2,
    [int]$Warm = 3,
    [int]$WatchSec = 120,
    [string]$Out = (Join-Path $PSScriptRoot "out\run-$(Get-Date -Format 'yyyyMMdd-HHmmss').json")
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
$m = Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force -PassThru

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Lab019Win {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
}
'@

# Every step of Connect-GpuVM, timed from inside the module without changing it.
$timed = 'Get-HostGpu', 'Sync-GpuVMDriver', 'Assert-VMCanStart', 'Start-VM', 'Update-GpuVMNetworkIsolation',
    'Get-GpuVMGuestCredential', 'Wait-GuestReady', 'Invoke-GuestPendingWork', 'Set-GuestCaptureMode', 'Get-GpuVMEndpoint',
    'Wait-SunshineReady', 'Repair-GuestConsoleSession', 'Set-SunshineVirtualDisplay', 'Set-GuestDisplayResolution',
    'Test-SunshineClientPaired', 'Register-MoonlightPairing', 'Install-GuestAudio', 'Set-SunshineAudioSink', 'Start-UnelevatedProcess',
    'Open-GuestSession', 'Get-GuestBootTime', 'Find-MoonlightStream', 'Wait-MoonlightStream', 'Start-GuestAudioCheck', 'Stop-GuestAudioCheck', 'Install-GuestGamepad'
& $m {
    param($names)
    $script:Lab019Clock = [Diagnostics.Stopwatch]::new()
    $script:Lab019Spans = [System.Collections.Generic.List[object]]::new()
    $script:Lab019Original = @{}
    foreach ($n in $names) {
        $cmd = Get-Command $n
        $script:Lab019Original[$n] = if ($cmd.CommandType -eq 'Function') { $cmd.ScriptBlock } else { $cmd }
        # Same parameters as the original (not @args: it loses "-Switch:`$value"), passed on as they were bound.
        $meta = [System.Management.Automation.CommandMetadata]::new($cmd)
        $binding = [System.Management.Automation.ProxyCommand]::GetCmdletBindingAttribute($meta)
        $params = [System.Management.Automation.ProxyCommand]::GetParamBlock($meta)
        $body = [scriptblock]::Create(@"
$binding
param($params)
`$start = `$script:Lab019Clock.Elapsed.TotalSeconds
try { & `$script:Lab019Original['$n'] @PSBoundParameters }
finally { `$script:Lab019Spans.Add([pscustomobject]@{ step = '$n'; start = [math]::Round(`$start, 2); seconds = [math]::Round(`$script:Lab019Clock.Elapsed.TotalSeconds - `$start, 2) }) }
"@)
        Set-Item -Path "function:script:$n" -Value $body
    }
} $timed

function Get-MoonlightWindow {
    Get-Process Moonlight -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and [Lab019Win]::IsWindowVisible($_.MainWindowHandle) } | Select-Object -First 1
}

# Mean brightness (0-255) of the Moonlight window, sampled down to 64x36.
function Get-WindowBrightness([IntPtr]$Handle) {
    $r = [Lab019Win+RECT]::new()
    if (-not [Lab019Win]::GetWindowRect($Handle, [ref]$r)) { return -1 }
    $w, $h = ($r.Right - $r.Left), ($r.Bottom - $r.Top)
    if ($w -lt 64 -or $h -lt 36) { return -1 }
    $full = [Drawing.Bitmap]::new($w, $h)
    $small = [Drawing.Bitmap]::new(64, 36)
    try {
        $g = [Drawing.Graphics]::FromImage($full); $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $full.Size); $g.Dispose()
        $g = [Drawing.Graphics]::FromImage($small); $g.DrawImage($full, 0, 0, 64, 36); $g.Dispose()
        $sum = 0
        for ($x = 0; $x -lt 64; $x++) { for ($y = 0; $y -lt 36; $y++) { $p = $small.GetPixel($x, $y); $sum += 0.2126 * $p.R + 0.7152 * $p.G + 0.0722 * $p.B } }
        [math]::Round($sum / (64 * 36), 1)
    }
    finally { $full.Dispose(); $small.Dispose() }
}

function Stop-Moonlight {
    Get-Process Moonlight -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3
}

function Invoke-OpenRun([string]$Kind, [int]$Index) {
    Stop-Moonlight
    if ($Kind -eq 'cold' -and (Get-VM $Name).State -ne 'Off') {
        Write-Host "  apagando $Name…"
        Stop-VM -Name $Name -Force
        while ((Get-VM $Name).State -ne 'Off') { Start-Sleep -Seconds 2 }
        Start-Sleep -Seconds 5
    }
    & $m { $script:Lab019Spans.Clear(); $script:Lab019Clock.Restart() }
    $clock = & $m { $script:Lab019Clock }
    $messages = [System.Collections.Generic.List[object]]::new()
    $global:GpuVMProgressSink = { param($message) $messages.Add([pscustomobject]@{ at = [math]::Round($clock.Elapsed.TotalSeconds, 2); message = $message }) }.GetNewClosure()
    $since = Get-Date
    $error1 = $null
    try { Connect-GpuVM -Name $Name -WarningAction SilentlyContinue }
    catch { $error1 = $_.Exception.Message }
    $returned = [math]::Round($clock.Elapsed.TotalSeconds, 2)

    # After the button goes back to "Abrir": when does the picture actually show up?
    $window = $stream = $light = $null
    $samples = [System.Collections.Generic.List[object]]::new()
    while (-not $error1 -and $clock.Elapsed.TotalSeconds - $returned -lt $WatchSec -and -not ($stream -and $light)) {
        $now = [math]::Round($clock.Elapsed.TotalSeconds, 2)
        $win = Get-MoonlightWindow
        if ($win -and -not $window) { $window = $now }
        if (-not $stream) {
            $log = Get-ChildItem $env:TEMP -Filter 'Moonlight*.log' -ErrorAction SilentlyContinue |
                Where-Object LastWriteTime -ge $since | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($log -and (Select-String -LiteralPath $log.FullName -Pattern 'Video stream is' -Quiet)) { $stream = $now }
        }
        if ($win) {
            $b = Get-WindowBrightness $win.MainWindowHandle
            $samples.Add([pscustomobject]@{ at = $now; brightness = $b })
            # The black stream is ~0; Moonlight's own "connecting" screen is dark grey, so only count after the first frame.
            if ($stream -and -not $light -and $b -gt 12) { $light = $now }
        }
        Start-Sleep -Milliseconds 250
    }
    $global:GpuVMProgressSink = $null
    # Sunshine's side of the black seconds: encoder tests, display changes and the session start, with its timestamps.
    $sunshine = @(if (-not $error1) { try {
        & $m {
            param($n)
            $s = Get-GpuVMState -Name $n
            $logs = Invoke-SunshineApi -Address (Get-GpuVMEndpoint -Name $n).Address -Credential (Get-SunshineCredential -State $s) -Path '/api/logs'
            # Raw: the display list Sunshine logs at start is multi-line JSON.
            ($logs -split "`n") | Select-Object -Last 4000
        } $Name
    }
    catch { "error: $($_.Exception.Message)" } })
    # What the guest's display script did this time: a mode change or displays turned off make Sunshine re-test.
    $display = if ($error1) { $null } else { try {
        & $m {
            param($n)
            $cred = Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n)
            Invoke-Command -VMName $n -Credential $cred -ScriptBlock {
                $file = Get-Item 'C:\GpuVM\resolution.json' -ErrorAction SilentlyContinue
                [pscustomobject]@{ written = if ($file) { $file.LastWriteTime.ToString('o') }; result = if ($file) { Get-Content -Raw $file.FullName } }
            }
        } $Name | Select-Object written, result
    }
    catch { "error: $($_.Exception.Message)" } }
    [pscustomobject]@{
        kind      = $Kind
        index     = $Index
        startedAt = $since.ToString('o')
        display   = $display
        sunshine  = $sunshine
        error     = $error1
        returned  = $returned
        window    = $window
        stream    = $stream
        light     = $light
        steps     = @(& $m { $script:Lab019Spans.ToArray() })
        messages  = @($messages)
        brightness = @($samples)
    }
}

$runs = [System.Collections.Generic.List[object]]::new()
try {
    # The first failure (not enough memory, Sunshine not answering) stops the lab: the next runs would only repeat it.
    for ($i = 1; $i -le $Cold; $i++) { Write-Host "frío $i/$Cold"; $runs.Add((Invoke-OpenRun 'cold' $i)); if ($runs[-1].error) { break } }
    if (-not ($runs | Where-Object error)) {
        for ($i = 1; $i -le $Warm; $i++) { Write-Host "en caliente $i/$Warm"; $runs.Add((Invoke-OpenRun 'warm' $i)); if ($runs[-1].error) { break } }
    }
}
finally {
    $runs | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 $Out
    Write-Host "Resultado: $Out"
}

foreach ($r in $runs) {
    Write-Host ("{0} {1}: botón vuelve a Abrir {2} s · ventana {3} s · primer cuadro {4} s · imagen visible {5} s {6}" -f
        $r.kind, $r.index, $r.returned, $r.window, $r.stream, $r.light, $(if ($r.error) { "· ERROR $($r.error)" }))
    $r.steps | Sort-Object seconds -Descending | Select-Object -First 6 | ForEach-Object { Write-Host ("    {0,-28} {1,6} s (desde {2} s)" -f $_.step, $_.seconds, $_.start) }
}
