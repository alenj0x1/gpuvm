# Sunshine's state inside the VM: service, process, listening ports and the end of its log.
# -Sink sets virtual_sink in sunshine.conf directly (for when the API does not answer) and restarts the service.
# pwsh -File labs\010-network-isolation\sunshine-status.ps1 [-Sink 'Altavoces (VB-Audio Virtual Cable)']
param(
    [string]$Name = (Get-VM | Where-Object Notes -like "Creada con GpuVM*" | Select-Object -First 1).Name,
    [string]$Sink
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$module = Get-Module GpuVM
$state = & $module { param($n) Get-GpuVMState -Name $n } $Name
$guest = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state

Invoke-Command -VMName $Name -Credential $guest -ArgumentList $Sink -ScriptBlock {
    param($sink)
    $conf = 'C:\Program Files\Sunshine\config\sunshine.conf'
    if ($sink) {
        $lines = @(Get-Content $conf | Where-Object { $_ -notmatch '^\s*virtual_sink\s*=' }) + "virtual_sink = $sink"
        # Without a BOM: Windows PowerShell's utf8 adds one, which would break the first key.
        [IO.File]::WriteAllLines($conf, [string[]]$lines, [Text.UTF8Encoding]::new($false))
        Get-Service | Where-Object Name -like '*sunshine*' | Restart-Service -Force
        Start-Sleep -Seconds 8
    }
    "== Servicio: $((@(Get-Service | Where-Object Name -like '*sunshine*' | ForEach-Object { "$($_.Name) $($_.Status)" }) -join ', '))"
    "== Procesos: " + (@(Get-Process sunshine -ErrorAction SilentlyContinue | ForEach-Object { "pid $($_.Id) sesion $($_.SessionId)" }) -join ', ')
    "== Escuchando: " + (@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -in 47984, 47989, 47990, 48010 | ForEach-Object LocalPort | Sort-Object -Unique) -join ', ')
    "== sunshine.conf (sink): " + (@(Get-Content $conf | Where-Object { $_ -match 'sink' }) -join ' | ')
    '== Log:'
    Get-Content 'C:\Program Files\Sunshine\config\sunshine.log' -Tail 30
}
