param([switch]$Once)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
# Runs elevated: modules resolve only from system folders and this one, never from the user's environment.
$env:PSModulePath = @("$PSHOME\Modules", "$([Environment]::GetFolderPath('System'))\WindowsPowerShell\v1.0\Modules", $PSScriptRoot) -join ';'
Import-Module (Join-Path $PSScriptRoot 'GpuVM\GpuVM.psd1') -Force -DisableNameChecking

# The UI can only call module functions; the ones that change downloadable components are excluded.
$blocked = @('Update-GpuVMComponent')
$allowed = (Get-Module GpuVM).ExportedFunctions.Keys | Where-Object { $_ -notin $blocked }

function global:Send-Event([hashtable]$Event) {
    [Console]::Out.WriteLine(($Event | ConvertTo-Json -Depth 10 -Compress))
    [Console]::Out.Flush()
}

function ConvertTo-Argument($Value) {
    if ($Value -is [System.Collections.IDictionary] -and $Value.Contains('user') -and $Value.Contains('password')) {
        return [pscredential]::new($Value['user'], (ConvertTo-SecureString $Value['password'] -AsPlainText -Force))
    }
    $Value
}

while ($null -ne ($line = [Console]::In.ReadLine())) {
    if (-not $line.Trim()) { continue }
    try { $request = $line | ConvertFrom-Json -AsHashtable }
    catch {
        Send-Event @{ id = $null; type = 'result'; ok = $false; error = 'Invalid request.' }
        continue
    }
    $id = $request['id']
    $global:GpuVMProgressSink = { param($message) Send-Event @{ id = $id; type = 'progress'; message = $message } }.GetNewClosure()
    try {
        # Exact names, case included: the service decides consent by them, and PowerShell would accept other case or a prefix.
        if ($request['cmd'] -isnot [string] -or $request['cmd'] -cnotin $allowed) { throw "Command not allowed: $($request['cmd'])" }
        $parameters = (Get-Command -Name $request['cmd'] -Module GpuVM).Parameters.Keys
        $arguments = @{}
        if ($request['args']) {
            foreach ($key in $request['args'].Keys) {
                if ($key -cnotin $parameters) { throw "Argument not allowed: $key" }
                $arguments[$key] = ConvertTo-Argument $request['args'][$key]
            }
        }
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
