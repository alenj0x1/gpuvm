# Diagnoses the end-to-end meter: saves what the host screen and the VM show around one Scroll Lock press,
# and how the measured pixel's brightness evolves. Run as administrator.
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$OutDir
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$vm = Get-LatencyVM -Name $Name
$log = [System.Collections.Generic.List[string]]::new()

$guestInfo = Invoke-Command -VMName $Name -Credential $vm.Guest -ScriptBlock {
    $p = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object CommandLine -like '*latency-target*'
    "target processes: $(@($p).Count) session: $(@($p | ForEach-Object { (Get-Process -Id $_.ProcessId).SessionId }) -join ',')"
}
$log.Add($guestInfo)

$variant = (Get-LatencyVariants)[0]
$session = Start-LatencyStream -VM $vm -Variant $variant
Start-Sleep -Seconds 25
Save-ScreenRegion -Path (Join-Path $OutDir '1-after-warmup.png')
$session.Process.Refresh()
$log.Add("moonlight window: $($session.Process.MainWindowHandle) title: $($session.Process.MainWindowTitle)")
$log.Add("foreground set: $([GpuVMLatency]::SetForegroundWindow($session.Process.MainWindowHandle))")
Start-Sleep -Milliseconds 300
[GpuVMLatency]::Key(0x1B)
Start-Sleep -Seconds 1
Save-ScreenRegion -Path (Join-Path $OutDir '2-after-esc.png')

$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$px = $bounds.Left + [int]($bounds.Width / 2); $py = $bounds.Top + [int]($bounds.Height / 2)
$log.Add("center brightness before: $([GpuVMLatency]::Brightness($px, $py))")
[GpuVMLatency]::Key(0x91)
$watch = [Diagnostics.Stopwatch]::StartNew()
$trace = while ($watch.ElapsedMilliseconds -lt 1500) { "{0:N0}:{1}" -f $watch.ElapsedMilliseconds, [GpuVMLatency]::Brightness($px, $py); Start-Sleep -Milliseconds 50 }
$log.Add("trace: $($trace -join ' ')")
Save-ScreenRegion -Path (Join-Path $OutDir '3-after-key.png')
[GpuVMLatency]::Key(0x91)
Stop-LatencyStream $session -VM $vm

$shot = Invoke-Command -VMName $Name -Credential $vm.Guest -ScriptBlock {
    $code = "Add-Type -AssemblyName System.Windows.Forms, System.Drawing; `$b = [System.Windows.Forms.SystemInformation]::VirtualScreen; `$bmp = New-Object System.Drawing.Bitmap `$b.Width, `$b.Height; [System.Drawing.Graphics]::FromImage(`$bmp).CopyFromScreen(`$b.Left, `$b.Top, 0, 0, `$bmp.Size); `$bmp.Save('C:\GpuVM\screen.png')"
    Set-Content C:\GpuVM\shot.ps1 $code
    $user = (Get-CimInstance Win32_ComputerSystem).UserName
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\GpuVM\shot.ps1'
    $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName GpuVM-Shot -Action $a -Principal $p -Force | Out-Null
    Remove-Item C:\GpuVM\screen.png -ErrorAction SilentlyContinue
    Start-ScheduledTask GpuVM-Shot; Start-Sleep 6
    Unregister-ScheduledTask GpuVM-Shot -Confirm:$false
    if (Test-Path C:\GpuVM\screen.png) { [Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\GpuVM\screen.png')) }
}
if ($shot) { [IO.File]::WriteAllBytes((Join-Path $OutDir '4-guest.png'), [Convert]::FromBase64String($shot)) }
$log | Set-Content (Join-Path $OutDir 'debug.txt')
