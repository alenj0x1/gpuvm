function Get-GpuVMExplorerSelection {
    <#
    .SYNOPSIS
    What is selected in the File Explorer windows of a running VM (the window used last first): what "Enviar a"
    sends to another machine. Read in the session of the user signed in at the VM's screen. The VM answers, so the
    paths are only used inside that same VM (Send-GpuVMFile -FromVM).
    .EXAMPLE
    Get-GpuVMExplorerSelection -Name win10
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    $guest = Get-GpuVMGuestCredential -State $state
    if (-not $guest) { throw "Save the Windows password of '$Name' to send from it." }
    if ((Get-VM -Name $Name).State -ne 'Running') { throw "The VM '$Name' is off." }
    $raw = Invoke-Command -VMName $Name -Credential $guest -ErrorAction Stop -ArgumentList $script:GuestFolderCode -ScriptBlock {
        param($folderCode)
        . ([scriptblock]::Create($folderCode))
        # C:\GpuVM only administrators can change (the script is written there as administrator); the answer comes
        # back through a folder of this run the user can write and the administrator only reads (security review
        # 2026-11-21, GuestFolders.ps1).
        $dir = 'C:\GpuVM'
        Protect-GpuVMGuestRoot -Path $dir
        $script = Join-Path $dir 'get-selection.ps1'
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        if (-not $user) { return @{ state = 'nosession' } }
        $drop = New-GpuVMUserFolder -Root $dir -User $user
        try {
            $out = Join-Path $drop 'selection.txt'
            Remove-GpuVMItem -Path $script
            # Shell windows come in the order they were opened; the one in front (or used last) goes first.
            Set-Content -Path $script -Encoding UTF8 -Value @"
Add-Type -Namespace GpuVM -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();'
`$front = [GpuVM.W]::GetForegroundWindow().ToInt64()
`$windows = @((New-Object -ComObject Shell.Application).Windows()) | Where-Object { `$_.Document -and `$_.Document.SelectedItems }
`$windows = @(`$windows | Where-Object { `$_.HWND -eq `$front }) + @(`$windows | Where-Object { `$_.HWND -ne `$front })
`$paths = foreach (`$w in `$windows) { `$sel = @(`$w.Document.SelectedItems() | ForEach-Object { `$_.Path } | Where-Object { `$_ -match '^[A-Za-z]:\\' }); if (`$sel) { `$sel; break } }
[IO.File]::WriteAllLines('$out', [string[]]@(`$paths), [Text.UTF8Encoding]::new(`$false))
"@
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
            $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask -TaskName 'GpuVM-Selection' -Action $action -Principal $principal -Force | Out-Null
            Start-ScheduledTask -TaskName 'GpuVM-Selection'
            for ($i = 0; $i -lt 40 -and -not (Test-Path $out); $i++) { Start-Sleep -Milliseconds 250 }
            Unregister-ScheduledTask -TaskName 'GpuVM-Selection' -Confirm:$false
            if (-not (Test-Path $out)) { return @{ state = 'timeout' } }
            Start-Sleep -Milliseconds 100
            $paths = @(Get-Content -LiteralPath $out -Encoding UTF8 | Where-Object { $_ })
            @{ state = 'ok'; paths = $paths }
        }
        finally { Remove-GpuVMFolder -Path $drop }
    }
    $raw = @($raw)[-1]
    switch (ConvertTo-GuestString $raw['state']) {
        'nosession' { throw "Nobody is signed in on the screen of '$Name'." }
        'ok' { }
        default { throw "'$Name' didn't answer in time; try again." }
    }
    # From the guest: at most 1000 paths, each a plain full path of bounded length.
    $paths = @($raw['paths'] | Select-Object -First 1000 | ForEach-Object { ConvertTo-GuestString $_ -MaxLength 1024 } |
        Where-Object { $_ -match '^[A-Za-z]:\\' -and $_ -notmatch '\\\.\.?(\\|$)' })
    [ordered]@{ name = $Name; paths = $paths; names = @($paths | ForEach-Object { Split-Path $_ -Leaf }) }
}
