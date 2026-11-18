# Lab 042, part 4: does the dock hurt the picture? With GpuVM's viewer showing the machine (open it from the app first,
# full screen or inside the app) and lab 041's moving bar on the machine's screen, PresentMon records the viewer's
# presents (GpuVMViewer.exe) in three states, per round: before (no prompt), with a real administrator prompt open and
# the dock down over the picture, and after answering it (dock gone). Per state: how Windows presents the picture
# (independent flip vs composed), frames, time between presents (median, p99) and until displayed.
# Run elevated, with the lab lock held: pwsh -File labs/042-admin-dock/dock-smooth.ps1 -Name win-gpu [-Rounds 3]
param(
    [string]$Name = 'win-gpu',
    [int]$Rounds = 3,
    [int]$Seconds = 6,
    [string]$PresentMon = (Join-Path $PSScriptRoot 'out\tools\PresentMon-2.6.0-x64.exe'),
    [string]$OutDir = (Join-Path $PSScriptRoot "out\smooth-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null
. (Join-Path $PSScriptRoot '..\..\tools\latency\common.ps1')
. (Join-Path $PSScriptRoot '..\041-latency-path\variants.ps1')
$vm = Get-LatencyVM -Name $Name
if (-not (Get-Process GpuVMViewer -ErrorAction SilentlyContinue)) { throw 'Abre la máquina en GpuVM primero (su imagen debe verse).' }
if (-not (Test-Path $PresentMon)) { throw "Falta PresentMon: $PresentMon" }
$session = New-PSSession -VMName $Name -Credential $vm.Guest
$results = [System.Collections.Generic.List[object]]::new()
Add-Type -Namespace Lab042 -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(System.IntPtr h, out int pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, System.IntPtr l);
public struct RECT { public int Left, Top, Right, Bottom; }
// Visible windows of a process, as "WxH" sizes.
public static string Sizes(int pid) {
    var list = new System.Collections.Generic.List<string>();
    EnumWindows((h, l) => { int p; GetWindowThreadProcessId(h, out p); RECT r;
        if (p == pid && IsWindowVisible(h) && GetWindowRect(h, out r)) list.Add((r.Right - r.Left) + "x" + (r.Bottom - r.Top));
        return true; }, System.IntPtr.Zero);
    return string.Join(",", list);
}
'@

function Measure-Presents([string]$Label, [int]$Round) {
    $csv = Join-Path $OutDir "pm-$Label-r$Round.csv"
    & $PresentMon --process_name GpuVMViewer.exe --output_file $csv --timed $Seconds --terminate_after_timed --no_console_stats --session_name "GpuVMLab042-$Label-$Round" --stop_existing_session | Out-Null
    # No file: the viewer presented nothing in the window (no new picture arrived).
    $rows = if (Test-Path $csv) { @(Import-Csv $csv | Where-Object { $_.SwapChainAddress -ne '0x0' }) } else { @() }
    $between = @($rows | ForEach-Object { [double]$_.MsBetweenPresents } | Where-Object { $_ -gt 0 } | Sort-Object)
    $until = @($rows | Where-Object { $_.MsUntilDisplayed -ne 'NA' } | ForEach-Object { [double]$_.MsUntilDisplayed } | Sort-Object)
    $app = Get-Process gpuvm -ErrorAction SilentlyContinue | Select-Object -First 1
    [pscustomobject]@{
        state = $Label; round = $Round; frames = $rows.Count
        fps = [math]::Round($rows.Count / $Seconds, 1)
        modes = ($rows | Group-Object PresentMode | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join '; '
        betweenMedianMs = if ($between) { [math]::Round($between[[int]($between.Count / 2)], 2) } else { $null }
        betweenP99Ms = if ($between) { [math]::Round($between[[math]::Min($between.Count - 1, [int]($between.Count * 0.99))], 2) } else { $null }
        untilDisplayedMedianMs = if ($until) { [math]::Round($until[[int]($until.Count / 2)], 2) } else { $null }
        appWindows = if ($app) { [Lab042.Win]::Sizes($app.Id) } else { '' }
    }
}

function Open-Prompt {
    Invoke-Command -Session $session -ScriptBlock {
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        $script = 'C:\Users\Public\gpuvm-lab042-smooth.ps1'
        Set-Content $script "Start-Process cmd.exe -ArgumentList '/c exit' -Verb RunAs" -Encoding UTF8
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $script"
        Register-ScheduledTask -TaskName GpuVM-Lab042Smooth -Action $a -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
        Start-ScheduledTask GpuVM-Lab042Smooth
        for ($i = 0; $i -lt 100 -and -not (Get-Process consent -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 50 }
        Unregister-ScheduledTask GpuVM-Lab042Smooth -Confirm:$false
        Remove-Item $script -ErrorAction SilentlyContinue
    }
}

try {
    Start-Lab041Target $vm 'gpu'
    Start-Sleep -Seconds 3
    for ($round = 1; $round -le $Rounds; $round++) {
        $results.Add((Measure-Presents 'before' $round))
        Open-Prompt
        # The dock is down once the app lists the prompt (poll ~1 s) and it lands (0.3 s).
        $p = $null
        for ($i = 0; $i -lt 40 -and -not ($p -and -not $p.reading); $i++) { Start-Sleep -Milliseconds 250; $p = & $vm.Module { param($n) Get-GuestAdminPromptState -Name $n } $Name }
        Start-Sleep -Seconds 2
        $results.Add((Measure-Presents 'dock' $round))
        if ($p) { try { Resolve-GpuVMAdminPrompt -Name $Name -Answer Deny -PromptId $p.id | Out-Null } catch { Write-Host "answer: $_" } }
        Start-Sleep -Seconds 3
        $results.Add((Measure-Presents 'after' $round))
        $results | Select-Object -Last 3 | Format-Table -AutoSize | Out-String | Write-Host
    }
}
finally {
    # A prompt still open is answered (Deny), never killed: killing consent.exe can leave the console on the secure desktop.
    try { $open = & $vm.Module { param($n) Get-GuestAdminPromptState -Name $n } $Name; if ($open) { Resolve-GpuVMAdminPrompt -Name $Name -Answer Deny -PromptId $open.id | Out-Null } } catch { }
    try { Start-Lab041Target $vm 'none' } catch { }
    Remove-PSSession $session -ErrorAction SilentlyContinue
    $results | ConvertTo-Json | Set-Content (Join-Path $OutDir 'results.json')
}
$results | Format-Table -AutoSize
