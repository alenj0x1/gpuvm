<#
.SYNOPSIS
Command-line shortcut for the GpuVM module.
.EXAMPLE
./gpuvm.ps1 check -Profile max-performance
./gpuvm.ps1 new -Name win11 -IsoPath D:\ISOs\Win11.iso -Profile max-performance -Start
./gpuvm.ps1 list
./gpuvm.ps1 sync-driver -Name win11
#>
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(ValueFromRemainingArguments)][object[]]$Rest
)
# If launched from Windows PowerShell 5.1, re-run under PowerShell 7 with the same arguments.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    # The MSI's pwsh first: an elevated console must not run a pwsh.exe that comes earlier in the PATH.
    $pwsh = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PowerShell\7\pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwsh)) { $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source }
    if (-not $pwsh) { throw 'GpuVM necesita PowerShell 7: https://aka.ms/powershell' }
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath $Command @Rest
    exit $LASTEXITCODE
}

# Usually run as administrator: modules only come from system folders and this repository, not the user's environment.
# The console gets its own PSModulePath back when the command ends.
$userModulePath = $env:PSModulePath
$env:PSModulePath = @("$PSHOME\Modules", "$([Environment]::GetFolderPath('System'))\WindowsPowerShell\v1.0\Modules", (Join-Path $PSScriptRoot 'src')) -join ';'
try { Import-Module (Join-Path $PSScriptRoot 'src\GpuVM\GpuVM.psd1') -Force } catch { $env:PSModulePath = $userModulePath; throw }

$commands = [ordered]@{
    'check'       = 'Test-GpuVMHost'
    'new'         = 'New-GpuVM'
    'set'         = 'Set-GpuVM'
    'list'        = 'Get-GpuVM'
    'sync-driver' = 'Sync-GpuVMDriver'
    'connect'     = 'Connect-GpuVM'
    'client-install' = 'Install-GpuVMClient'
    'components-update' = 'Update-GpuVMComponent'
    'remove'      = 'Remove-GpuVM'
    'repair'      = 'Repair-GpuVMState'
    'profiles'    = 'Get-GpuVMProfile'
    'lab-new'     = 'New-GpuVMLab'
    'lab-add'     = 'Add-GpuVMLabResult'
    'lab'         = 'Get-GpuVMLab'
    'lab-close'   = 'Close-GpuVMLab'
}

if (-not $commands.Contains($Command)) {
    Write-Host 'Uso: ./gpuvm.ps1 <comando> [-Parámetro valor ...]'
    foreach ($key in $commands.Keys) { Write-Host ('  {0,-18} {1}' -f $key, $commands[$key]) }
    Write-Host 'Ayuda de cada comando: Get-Help <Cmdlet> -Detailed'
    $env:PSModulePath = $userModulePath
    return
}

# Turns "-Name value -Switch" into a hashtable for splatting.
$params = @{}
for ($i = 0; $i -lt $Rest.Count; $i++) {
    $token = [string]$Rest[$i]
    # -Name:value (e.g. -Confirm:$false)
    if ($token -match '^-(\w+):(.*)$') {
        $value = $Matches[2]
        $params[$Matches[1]] = if ($value -in '$false', 'false') { $false } elseif ($value -in '$true', 'true') { $true } else { $value }
        continue
    }
    if ($token -notmatch '^-(\w+)$') { $env:PSModulePath = $userModulePath; throw "Argumento inesperado: $token" }
    $key = $Matches[1]
    $next = if ($i + 1 -lt $Rest.Count) { $Rest[$i + 1] } else { $null }
    # A negative number (-3) is a value, not another parameter.
    $nextIsParam = $null -ne $next -and ([string]$next -match '^-[A-Za-z]\w*(:.*)?$')
    if ($null -eq $next -or $nextIsParam) { $params[$key] = $true }
    else { $params[$key] = $next; $i++ }
}

$result = try { & $commands[$Command] @params } finally { $env:PSModulePath = $userModulePath }
if ($Command -eq 'check') { $result | Format-Table Status, Name, Detail -AutoSize -Wrap }
elseif ($Command -eq 'lab' -and $params['Lab']) { $result | Format-List Id, Title, Hypothesis, Status, Conclusion; $result.Metrics | Format-Table -AutoSize }
else { $result }
