# Lab 055: presses a button of GpuVM's window by its accessible name (UI Automation), as a person's click would.
# Windows PowerShell 5.1.
param([string]$Button = 'Open')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$p = Get-Process gpuvm | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
if (-not $p) { 'no GpuVM window'; exit 1 }
$win = [Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle)
$cond = New-Object Windows.Automation.AndCondition(
    (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button)),
    (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty, $Button)))
$deadline = (Get-Date).AddSeconds(10)
do { $b = $win.FindFirst([Windows.Automation.TreeScope]::Descendants, $cond); if (-not $b) { Start-Sleep -Milliseconds 300 } } while (-not $b -and (Get-Date) -lt $deadline)
if (-not $b) { "button '$Button' not found"; exit 1 }
# A real mouse click on the button's centre (UIA Invoke only focused WebView2's button).
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Click055 {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
'@
[Click055]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 300
$r = $b.Current.BoundingRectangle
[Click055]::SetCursorPos([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2)) | Out-Null
[Click055]::mouse_event(0x2, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [Click055]::mouse_event(0x4, 0, 0, 0, [UIntPtr]::Zero)
"clicked '$Button' at $([int]($r.X + $r.Width / 2)),$([int]($r.Y + $r.Height / 2))"
