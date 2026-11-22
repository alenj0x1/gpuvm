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

function Resolve-GpuVMStreamFps {
    param($Fps, [double]$Hz)
    if ([int]$Fps -gt 0) { return [int]$Fps }
    $hz = if ($Hz -gt 0) { [math]::Round($Hz) } else { [math]::Round([GpuVMHostDisplay]::PrimaryRefresh()) }
    if ($hz -lt 30) { return 60 }
    [int][math]::Min(240, $hz)
}

# The driver reads its settings when it starts: the device is restarted when the rate was missing.
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

# The Virtual Display Driver starts in the FIRST <resolution> of its settings; read when it starts, so no restart here.
function Set-GuestVddPreferredMode {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][ValidateRange(640, 7680)][int]$Width,
        [Parameter(Mandatory)][ValidateRange(480, 4320)][int]$Height,
        [Parameter(Mandatory)][ValidateRange(24, 500)][int]$Hz
    )
    $changed = Invoke-Guest -Name $Name -Credential $Credential -ArgumentList $Width, $Height, $Hz -ScriptBlock {
        param($w, $h, $hz)
        $path = 'C:\VirtualDisplayDriver\vdd_settings.xml'
        if (-not (Test-Path -LiteralPath $path)) { return $false }
        [xml]$xml = Get-Content -LiteralPath $path -Raw
        $list = $xml.SelectSingleNode('//resolutions')
        if (-not $list) { return $false }
        $first = @($list.SelectNodes('resolution'))[0]
        if ($first -and [int]$first.width -eq $w -and [int]$first.height -eq $h -and [int]$first.refresh_rate -eq $hz) { return $false }
        foreach ($r in @($list.SelectNodes('resolution'))) { if ([int]$r.width -eq $w -and [int]$r.height -eq $h) { [void]$list.RemoveChild($r) } }
        $node = $xml.CreateElement('resolution')
        foreach ($pair in @(@('width', $w), @('height', $h), @('refresh_rate', $hz))) {
            $e = $xml.CreateElement($pair[0]); $e.InnerText = "$($pair[1])"; [void]$node.AppendChild($e)
        }
        [void]$list.PrependChild($node)
        $xml.Save($path)
        $true
    }
    [bool](@($changed)[-1] -eq $true)
}
