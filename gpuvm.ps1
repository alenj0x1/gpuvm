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
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $pwsh) { throw 'GpuVM necesita PowerShell 7: https://aka.ms/powershell' }
    & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath $Command @Rest
    exit $LASTEXITCODE
}

Import-Module (Join-Path $PSScriptRoot 'src\GpuVM\GpuVM.psd1') -Force

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
    if ($token -notmatch '^-(\w+)$') { throw "Argumento inesperado: $token" }
    $key = $Matches[1]
    $next = if ($i + 1 -lt $Rest.Count) { $Rest[$i + 1] } else { $null }
    # A negative number (-3) is a value, not another parameter.
    $nextIsParam = $null -ne $next -and ([string]$next -match '^-[A-Za-z]\w*(:.*)?$')
    if ($null -eq $next -or $nextIsParam) { $params[$key] = $true }
    else { $params[$key] = $next; $i++ }
}

$result = & $commands[$Command] @params
if ($Command -eq 'check') { $result | Format-Table Status, Name, Detail -AutoSize -Wrap }
elseif ($Command -eq 'lab' -and $params['Lab']) { $result | Format-List Id, Title, Hypothesis, Status, Conclusion; $result.Metrics | Format-Table -AutoSize }
else { $result }
