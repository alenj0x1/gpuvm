# Gives GpuVM's viewer window the keyboard without clicking into the picture (a click there would reach the VM:
# pause a video, press a button). Windows only lets the process with the last input change the foreground, so an Alt
# tap comes first. Prints whether it worked.
Add-Type -Namespace FV -Name W -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
'@
$v = Get-Process GpuVMViewer -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
if (-not $v) { return 'no viewer' }
[FV.W]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [FV.W]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
[void][FV.W]::SetForegroundWindow($v.MainWindowHandle)
Start-Sleep -Milliseconds 300
if ([FV.W]::GetForegroundWindow() -eq $v.MainWindowHandle) { 'viewer in front' } else { 'not in front' }
