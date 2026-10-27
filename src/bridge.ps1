# Bridge between the desktop app and the GpuVM module.
# Reads one JSON request per line from stdin: {"id": "...", "cmd": "Get-GpuVMOverview", "args": {...}}
# and writes one JSON line per event to stdout:
#   {"id", "type": "progress", "message"}   progress (Write-Step)
#   {"id", "type": "warning", "message"}    warning (Write-Warning)
#   {"id", "type": "result", "ok", "data" | "error"}
# With -Once it handles a single request and exits (long jobs run in their own process).
param([switch]$Once)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
Import-Module (Join-Path $PSScriptRoot 'GpuVM\GpuVM.psd1') -Force -DisableNameChecking

# The UI can only call module functions; the ones that change downloadable components are excluded.
$blocked = @('Update-GpuVMComponent')
$allowed = (Get-Module GpuVM).ExportedFunctions.Keys | Where-Object { $_ -notin $blocked }

function global:Send-Event([hashtable]$Event) {
    [Console]::Out.WriteLine(($Event | ConvertTo-Json -Depth 10 -Compress))
    [Console]::Out.Flush()
}

# {"user","password"} → PSCredential; everything else is passed as is.
function ConvertTo-Argument($Value) {
    if ($Value -is [System.Collections.IDictionary] -and $Value.Contains('user') -and $Value.Contains('password')) {
        return [pscredential]::new($Value['user'], (ConvertTo-SecureString $Value['password'] -AsPlainText -Force))
    }
    $Value
}

while ($null -ne ($line = [Console]::In.ReadLine())) {
    if (-not $line.Trim()) { continue }
    $request = $line | ConvertFrom-Json -AsHashtable
    $id = $request['id']
    $global:GpuVMProgressSink = { param($message) Send-Event @{ id = $id; type = 'progress'; message = $message } }.GetNewClosure()
    try {
        if ($request['cmd'] -notin $allowed) { throw "Comando no permitido: $($request['cmd'])" }
        $arguments = @{}
        if ($request['args']) { foreach ($key in $request['args'].Keys) { $arguments[$key] = ConvertTo-Argument $request['args'][$key] } }
        # Warnings are sent as soon as they appear, not at the end of a 15-minute job.
        $data = [System.Collections.Generic.List[object]]::new()
        & $request['cmd'] @arguments 3>&1 6>$null | ForEach-Object {
            if ($_ -is [System.Management.Automation.WarningRecord]) {
                Send-Event @{ id = $id; type = 'warning'; message = $_.Message }
            }
            else { $data.Add($_) }
        }
        Send-Event @{ id = $id; type = 'result'; ok = $true; data = @($data) }
    }
    catch {
        Send-Event @{ id = $id; type = 'result'; ok = $false; error = $_.Exception.Message }
    }
    if ($Once) { break }
}
