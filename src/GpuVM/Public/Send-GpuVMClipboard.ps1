function Send-GpuVMClipboard {
    <#
    .SYNOPSIS
    Puts the text copied on this PC into the VM's clipboard, ready to paste with Ctrl+V. It only goes from the PC to
    the VM: the VM never reads this PC's clipboard, so a damaged or infected VM cannot leave anything in it.
    .EXAMPLE
    Send-GpuVMClipboard -Name win10
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        # Without -Text, the text currently copied on this PC.
        [string]$Text
    )
    Assert-Admin
    if (-not $PSBoundParameters.ContainsKey('Text')) { $Text = Get-Clipboard -Raw }
    if ([string]::IsNullOrEmpty($Text)) { throw 'No hay texto copiado en este equipo.' }
    if ($Text.Length -gt 1MB) { throw 'El texto copiado es demasiado largo (más de un millón de caracteres).' }
    $state = Get-GpuVMState -Name $Name
    $guest = Get-GpuVMGuestCredential -State $state
    if (-not $guest) { throw 'Guarda la contraseña de Windows de la VM para poder pegar en ella.' }
    if ((Get-VM -Name $Name).State -ne 'Running') { throw "La VM '$Name' está apagada." }

    $raw = Invoke-Command -VMName $Name -Credential $guest -ErrorAction Stop -ArgumentList $Text -ScriptBlock {
        param($text)
        # The clipboard belongs to the user's desktop session, so a task in that session sets it.
        $dir = 'C:\GpuVM'
        $file = Join-Path $dir 'clipboard.txt'
        $done = Join-Path $dir 'clipboard.done'
        $script = Join-Path $dir 'set-clipboard.ps1'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText($file, $text, [Text.UTF8Encoding]::new($false))
        Set-Content -Path $script -Encoding UTF8 -Value @"
Get-Content -Raw -Encoding UTF8 -LiteralPath '$file' | Set-Clipboard
Remove-Item -LiteralPath '$file' -Force
Set-Content -LiteralPath '$done' -Value ok
"@
        Remove-Item $done -Force -ErrorAction SilentlyContinue
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        if (-not $user) { Remove-Item $file -Force; return 'nosession' }
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName 'GpuVM-Clipboard' -Action $action -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName 'GpuVM-Clipboard'
        for ($i = 0; $i -lt 20 -and -not (Test-Path $done); $i++) { Start-Sleep -Milliseconds 250 }
        Unregister-ScheduledTask -TaskName 'GpuVM-Clipboard' -Confirm:$false
        Remove-Item $file -Force -ErrorAction SilentlyContinue
        if (Test-Path $done) { 'ok' } else { 'timeout' }
    }
    switch ([string](@($raw)[0])) {
        'ok' { Write-Step 'Texto listo en la VM: pégalo con Ctrl+V' }
        'nosession' { throw 'No hay una sesión iniciada en la pantalla de la VM.' }
        default { throw 'La VM no respondió a tiempo; vuelve a intentarlo.' }
    }
    [ordered]@{ name = $Name; characters = $Text.Length }
}
