# Inside the VM, with a sound playing: captures each active output with WASAPI loopback (what Sunshine does) and
# reports the peak it reads, from PowerShell Direct (session 0) and from the signed-in user's session.
# pwsh -File labs\010-network-isolation\audio-loopback.ps1
param(
    [string]$Name = (Get-VM | Where-Object Notes -like "Creada con GpuVM*" | Select-Object -First 1).Name,
    [int]$Seconds = 4
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$module = Get-Module GpuVM
$state = & $module { param($n) Get-GpuVMState -Name $n } $Name
$guest = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state

$capture = @'
param([int]$Seconds, [string]$Out)
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class Loopback {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class En {}
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator { int EnumAudioEndpoints(int f, int m, out IMMDeviceCollection c); }
    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection { int GetCount(out int c); int Item(int i, out IMMDevice d); }
    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice { int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); int NotImpl(); int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id); }
    [Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient {
        int Initialize(int share, int flags, long dur, long period, IntPtr fmt, IntPtr session);
        int GetBufferSize(out uint n); int GetStreamLatency(out long l); int GetCurrentPadding(out uint p);
        int IsFormatSupported(int s, IntPtr f, out IntPtr c); int GetMixFormat(out IntPtr f); int GetDevicePeriod(out long d, out long m);
        int Start(); int Stop(); int Reset(); int SetEventHandle(IntPtr h); int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object o);
    }
    [Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioCaptureClient { int GetBuffer(out IntPtr data, out uint frames, out uint flags, out long pos, out long qpc); int ReleaseBuffer(uint n); int GetNextPacketSize(out uint n); }
    public static List<string> Run(int seconds) {
        var r = new List<string>();
        IMMDeviceCollection col; ((IMMDeviceEnumerator)new En()).EnumAudioEndpoints(0, 1, out col);
        int n; col.GetCount(out n);
        for (int i = 0; i < n; i++) {
            IMMDevice d; col.Item(i, out d); string id; d.GetId(out id);
            try {
                var iid = typeof(IAudioClient).GUID; object o; d.Activate(ref iid, 23, IntPtr.Zero, out o);
                var ac = (IAudioClient)o; IntPtr fmt; ac.GetMixFormat(out fmt);
                int bits = Marshal.ReadInt16(fmt, 14); int ch = Marshal.ReadInt16(fmt, 2);
                int hr = ac.Initialize(0, 0x00020000, 2000000, 0, fmt, IntPtr.Zero);
                if (hr != 0) { r.Add(id + " Initialize 0x" + hr.ToString("X")); continue; }
                var cid = typeof(IAudioCaptureClient).GUID; object co; ac.GetService(ref cid, out co); var cc = (IAudioCaptureClient)co;
                ac.Start(); float peak = 0; long frames = 0, silentPackets = 0, packets = 0;
                var end = DateTime.Now.AddSeconds(seconds);
                while (DateTime.Now < end) {
                    uint size; cc.GetNextPacketSize(out size);
                    while (size > 0) {
                        IntPtr data; uint nf, flags; long p, q; cc.GetBuffer(out data, out nf, out flags, out p, out q);
                        packets++; frames += nf; if ((flags & 2) != 0) silentPackets++;
                        else if (bits == 32) { for (int k = 0; k < nf * ch; k++) { float v = Math.Abs(BitConverter.ToSingle(BitConverter.GetBytes(Marshal.ReadInt32(data, k * 4)), 0)); if (v > peak) peak = v; } }
                        cc.ReleaseBuffer(nf); cc.GetNextPacketSize(out size);
                    }
                    System.Threading.Thread.Sleep(10);
                }
                ac.Stop();
                r.Add(id + " bits=" + bits + " ch=" + ch + " packets=" + packets + " silent=" + silentPackets + " frames=" + frames + " peak=" + peak.ToString("0.000"));
            } catch (Exception ex) { r.Add(id + " " + ex.Message); }
        }
        return r;
    }
}
"@
$lines = [Loopback]::Run($Seconds)
if ($Out) { $lines | Set-Content -Encoding utf8 $Out } else { $lines }
'@

$result = Invoke-Command -VMName $Name -Credential $guest -ArgumentList $capture, $Seconds -ScriptBlock {
    param($code, $s)
    $dir = 'C:\GpuVM\lab010'
    New-Item -ItemType Directory -Force $dir | Out-Null
    Set-Content -Encoding utf8 "$dir\capture.ps1" $code
    $user = (Get-CimInstance Win32_ComputerSystem).UserName
    $register = {
        param($task, $command)
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden $command"
        Register-ScheduledTask -TaskName $task -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive) -Force | Out-Null
        Start-ScheduledTask -TaskName $task
    }
    try {
        & $register 'GpuVM-Lab010-Play' "-Command `$p=[Media.SoundPlayer]::new('C:\Windows\Media\Alarm01.wav');`$p.PlayLooping();Start-Sleep $(2 * $s + 4)"
        Start-Sleep -Milliseconds 800
        & $register 'GpuVM-Lab010-Capture' "-File $dir\capture.ps1 -Seconds $s -Out $dir\user.txt"
        $session0 = & ([scriptblock]::Create($code)) -Seconds $s
        $deadline = (Get-Date).AddSeconds($s + 20)
        while (-not (Test-Path "$dir\user.txt") -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
        $names = @{}
        Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render' | ForEach-Object {
            $names[$_.PSChildName] = (Get-ItemProperty (Join-Path $_.PSPath 'Properties')).'{a45c254e-df1c-4efd-8020-67d146a850e0},2'
        }
        $label = { param($line) foreach ($k in $names.Keys) { if ($line -like "*$k*") { return $line.Replace("{0.0.0.00000000}.$k", $names[$k]) } }; $line }
        [pscustomobject]@{
            session0 = @($session0 | ForEach-Object { & $label $_ })
            user     = @(if (Test-Path "$dir\user.txt") { Get-Content "$dir\user.txt" | ForEach-Object { & $label $_ } } else { 'sin resultado' })
            sunshine = @(Get-CimInstance Win32_Process -Filter "Name='sunshine.exe'" | ForEach-Object { "pid $($_.ProcessId) sesion $($_.SessionId) $((Invoke-CimMethod -InputObject $_ -MethodName GetOwner).User)" })
        }
    }
    finally {
        'GpuVM-Lab010-Play', 'GpuVM-Lab010-Capture' | ForEach-Object { Unregister-ScheduledTask -TaskName $_ -Confirm:$false -ErrorAction SilentlyContinue }
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    }
}
Write-Host "`n== Loopback desde la sesion 0 (PowerShell Direct)" -ForegroundColor Cyan
$result.session0
Write-Host "`n== Loopback desde la sesion del usuario" -ForegroundColor Cyan
$result.user
Write-Host "`n== Procesos de Sunshine" -ForegroundColor Cyan
$result.sunshine
