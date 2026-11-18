function Send-GpuVMClipboard {
    <#
    .SYNOPSIS
    Puts what was copied on this PC into the VM's clipboard, ready to paste with Ctrl+V: text, an image (PNG) or
    files (copied first to Desktop\Recibidos, then put on the clipboard so they paste in Explorer). It only goes from
    the PC to the VM: the VM never reads this PC's clipboard, so a damaged or infected VM cannot leave anything in it.
    .EXAMPLE
    Send-GpuVMClipboard -Name win10
    .EXAMPLE
    Send-GpuVMClipboard -Name win10 -Files 'C:\Users\me\Pictures\foto.png'
    #>
    [CmdletBinding(DefaultParameterSetName = 'Text')]
    param(
        [Parameter(Mandatory)][string]$Name,
        # Without -Text, -Image or -Files, the text currently copied on this PC.
        [Parameter(ParameterSetName = 'Text')][string]$Text,
        # A PNG, as base64 (the app reads it from the clipboard).
        [Parameter(Mandatory, ParameterSetName = 'Image')][string]$Image,
        [Parameter(Mandatory, ParameterSetName = 'Files')][string[]]$Files,
        [Parameter(ParameterSetName = 'Files')][ValidatePattern('^[^\\/:*?"<>|\x00-\x1f]{1,60}$')][string]$Folder = 'Recibidos'
    )
    Assert-Admin
    $payload = $null
    $kind = $PSCmdlet.ParameterSetName.ToLowerInvariant()
    switch ($kind) {
        'text' {
            if (-not $PSBoundParameters.ContainsKey('Text')) { $Text = Get-Clipboard -Raw }
            if ([string]::IsNullOrEmpty($Text)) { throw 'No hay texto copiado en este equipo.' }
            if ($Text.Length -gt 1MB) { throw 'El texto copiado es demasiado largo (más de un millón de caracteres).' }
            $payload = [Text.Encoding]::UTF8.GetBytes($Text)
        }
        'image' {
            if ($Image.Length -gt 40MB) { throw 'La imagen copiada es demasiado grande (más de 30 MB).' }
            try { $payload = [Convert]::FromBase64String($Image) } catch { throw 'La imagen copiada no es válida.' }
            # Only a PNG goes in: the guest decodes it, so nothing else is handed to its image code.
            if ($payload.Length -lt 8 -or [BitConverter]::ToString($payload, 0, 8) -ne '89-50-4E-47-0D-0A-1A-0A') { throw 'La imagen copiada no es válida.' }
        }
    }
    $state = Get-GpuVMState -Name $Name
    $guest = Get-GpuVMGuestCredential -State $state
    if (-not $guest) { throw 'Guarda la contraseña de Windows de la VM para pegar en ella.' }
    if ((Get-VM -Name $Name).State -ne 'Running') { throw "La VM '$Name' está apagada." }

    $received = @()
    if ($kind -eq 'files') {
        $sent = Send-GpuVMFile -Name $Name -Path $Files -Folder $Folder
        $received = @($sent['items'])
    }

    $raw = Invoke-Command -VMName $Name -Credential $guest -ErrorAction Stop -ArgumentList $kind, $payload, $Folder, $received -ScriptBlock {
        param($kind, [byte[]]$payload, $folder, [string[]]$received)
        # The clipboard belongs to the user's desktop session, so a task in that session sets it.
        $dir = 'C:\GpuVM'
        $file = Join-Path $dir 'clipboard.bin'
        $list = Join-Path $dir 'clipboard.txt'
        $done = Join-Path $dir 'clipboard.done'
        $script = Join-Path $dir 'set-clipboard.ps1'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        if (-not $user) { return 'nosession' }
        if ($kind -eq 'files') {
            # The received items, by full path in the signed-in user's Desktop\<folder>.
            $sid = ([Security.Principal.NTAccount]$user).Translate([Security.Principal.SecurityIdentifier]).Value
            $profile = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid").ProfileImagePath
            $shell = (Get-ItemProperty "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction SilentlyContinue).Desktop
            $desktop = if ($shell) { $shell -replace '%USERPROFILE%', $profile } else { Join-Path $profile 'Desktop' }
            $paths = $received | ForEach-Object { Join-Path (Join-Path $desktop $folder) $_ }
            [IO.File]::WriteAllLines($list, [string[]]$paths, [Text.UTF8Encoding]::new($false))
        }
        else { [IO.File]::WriteAllBytes($file, $payload) }
        $set = switch ($kind) {
            'text' { "Set-Clipboard -Value ([IO.File]::ReadAllText('$file', [Text.Encoding]::UTF8))" }
            'image' {
                "Add-Type -AssemblyName System.Windows.Forms, System.Drawing`n" +
                "`$img = [Drawing.Image]::FromStream([IO.MemoryStream]::new([IO.File]::ReadAllBytes('$file')))`n" +
                "[Windows.Forms.Clipboard]::SetImage(`$img)"
            }
            'files' { "Set-Clipboard -Path (Get-Content -Encoding UTF8 -LiteralPath '$list')" }
        }
        Set-Content -Path $script -Encoding UTF8 -Value @"
try { $set } finally { Remove-Item -LiteralPath '$file', '$list' -Force -ErrorAction SilentlyContinue }
Set-Content -LiteralPath '$done' -Value ok
"@
        Remove-Item $done -Force -ErrorAction SilentlyContinue
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName 'GpuVM-Clipboard' -Action $action -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName 'GpuVM-Clipboard'
        for ($i = 0; $i -lt 40 -and -not (Test-Path $done); $i++) { Start-Sleep -Milliseconds 250 }
        Unregister-ScheduledTask -TaskName 'GpuVM-Clipboard' -Confirm:$false
        Remove-Item $file, $list -Force -ErrorAction SilentlyContinue
        if (Test-Path $done) { 'ok' } else { 'timeout' }
    }
    switch ([string](@($raw)[0])) {
        'ok' { Write-Step 'Listo en la VM: pégalo con Ctrl+V' }
        'nosession' { throw 'No hay una sesión iniciada en la pantalla de la VM.' }
        default { throw 'La VM no respondió a tiempo; vuelve a intentarlo.' }
    }
    $out = [ordered]@{ name = $Name; kind = $kind }
    if ($kind -eq 'text') { $out['characters'] = $Text.Length }
    if ($kind -eq 'files') { $out['items'] = $received }
    $out
}
