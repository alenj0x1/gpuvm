# "fps = 0" means "the host monitor's refresh rate". When the VM's virtual display runs at the same rate as the monitor
# that shows Moonlight, every streamed frame lands on one refresh: half the stutters and the same or lower input
# latency with V-Sync on, so the picture never tears (lab 022). The rate is read when the VM is opened, so it follows
# the monitor in use.

if (-not ('GpuVMHostDisplay' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class GpuVMHostDisplay {
    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct RATIONAL { public uint Numerator, Denominator; }
    [StructLayout(LayoutKind.Sequential)] struct PATH_SOURCE { public LUID Adapter; public uint Id; public uint ModeIndex; public uint Flags; }
    [StructLayout(LayoutKind.Sequential)] struct PATH_TARGET {
        public LUID Adapter; public uint Id; public uint ModeIndex; public uint Technology; public uint Rotation; public uint Scaling;
        public RATIONAL Refresh; public uint ScanLine; public int Available; public uint Flags;
    }
    [StructLayout(LayoutKind.Sequential)] struct PATH { public PATH_SOURCE Source; public PATH_TARGET Target; public uint Flags; }
    [StructLayout(LayoutKind.Sequential)] struct POINTL { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct SOURCE_MODE { public uint Width, Height, Format; public POINTL Position; }
    [StructLayout(LayoutKind.Explicit, Size = 64)] struct MODE {
        [FieldOffset(0)] public uint InfoType; [FieldOffset(4)] public uint Id; [FieldOffset(8)] public LUID Adapter;
        [FieldOffset(16)] public SOURCE_MODE Source;
    }
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths, [Out] PATH[] pathArray, ref uint modes, [Out] MODE[] modeArray, IntPtr topology);

    // Refresh rate in Hz of the primary display (the one at 0,0), or 0 when it can't be read (no desktop session).
    public static double PrimaryRefresh() {
        uint paths, modes;
        if (GetDisplayConfigBufferSizes(2, out paths, out modes) != 0) return 0;
        var pathArray = new PATH[paths];
        var modeArray = new MODE[modes];
        if (QueryDisplayConfig(2, ref paths, pathArray, ref modes, modeArray, IntPtr.Zero) != 0) return 0;
        double first = 0;
        for (int i = 0; i < paths; i++) {
            var r = pathArray[i].Target.Refresh;
            if (r.Denominator == 0) continue;
            double hz = (double)r.Numerator / r.Denominator;
            if (first == 0) first = hz;
            uint m = pathArray[i].Source.ModeIndex;
            if (m < modes && modeArray[m].InfoType == 1 && modeArray[m].Source.Position.X == 0 && modeArray[m].Source.Position.Y == 0) return hz;
        }
        return first;
    }
}
'@
}

# The frame rate to stream with: the client's, or the host monitor's when it is 0 (between 30 and 240; 60 if unknown).
function Resolve-GpuVMStreamFps {
    param($Fps)
    if ([int]$Fps -gt 0) { return [int]$Fps }
    $hz = [math]::Round([GpuVMHostDisplay]::PrimaryRefresh())
    if ($hz -lt 30) { return 60 }
    [int][math]::Min(240, $hz)
}

# Makes sure the VM's virtual display offers this refresh rate: adds it to the Virtual Display Driver's settings and
# restarts the device when it was missing (the driver reads them when it starts). Runs as administrator in the guest.
# Returns $true when it added the rate.
function Add-GuestRefreshRate {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][ValidateRange(30, 240)][int]$Hz
    )
    $added = Invoke-Guest -Name $Name -Credential $Credential -ArgumentList $Hz -ScriptBlock {
        param($hz)
        $path = 'C:\VirtualDisplayDriver\vdd_settings.xml'
        if (-not (Test-Path -LiteralPath $path)) { return $false }
        [xml]$xml = Get-Content -LiteralPath $path -Raw
        $rates = @($xml.SelectNodes('//g_refresh_rate'))
        if (-not $rates.Count -or "$hz" -in @($rates | ForEach-Object { $_.InnerText.Trim() })) { return $false }
        $node = $xml.CreateElement('g_refresh_rate')
        $node.InnerText = "$hz"
        [void]$rates[0].ParentNode.AppendChild($node)
        $xml.Save($path)
        $device = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains 'Root\MttVDD' }
        if (-not $device) { return $false }
        $device | Disable-PnpDevice -Confirm:$false
        Start-Sleep -Seconds 2
        $device | Enable-PnpDevice -Confirm:$false
        Start-Sleep -Seconds 6
        $true
    }
    [bool](@($added)[-1] -eq $true)
}
