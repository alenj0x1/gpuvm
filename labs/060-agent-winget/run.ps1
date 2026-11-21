# Lab 060: winget for the agent's user, end to end on a disposable copy of an agent template.
#   1. A copy (New-GpuVM -Template -Disposable, 4 GB) and THIS checkout's Install-GpuVMAgent on it: the very step
#      Update-GpuVMTemplate runs in its temporary copy, which now provisions App Installer (Install-GuestWinget).
#   2. The power cycle the template update does, so `agent` signs in again and gets the provisioned package.
#   3. As `agent`, through the agent's exec.run (what the MCP `run` tool uses: powershell.exe -NoProfile
#      -NonInteractive -Command ...): winget --version, winget source list, a search WITHOUT --accept-* flags and empty
#      stdin (must not wait on an agreement prompt), and winget install Mozilla.Firefox --scope user; firefox.exe must
#      then be in the agent's profile.
#   4. Install-GpuVMAgent once more: winget must be 'current' (what every copy of an updated template pays).
#   5. What Windows says as administrator: provisioned version, per-user state, policies, the stamp.
# Every step is timed; out\<label>.json keeps the result even when a step fails. The copy is deleted at the end
# (-Keep leaves it). Run elevated, with nothing else needing the memory (a 4 GB copy needs ~4.3 GB free).
#   pwsh -NoProfile -File labs\060-agent-winget\run.ps1
param(
    [string]$Template = 'agent-tpl',
    [ValidatePattern('^[\w-]{1,40}$')][string]$Name = 'lab060',
    [int]$MemoryGB = 4,
    [string]$Label = 'run',
    [switch]$Keep
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null
Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
$m = Get-Module GpuVM
function Step([string]$Text) { Write-Host ("[{0:mm\:ss}] {1}" -f $sw.Elapsed, $Text) }

# Preflight: rights, the agent build, the template, a free name, the memory.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')) { throw 'Run it elevated.' }
$null = & $m { Get-AgentPackage }   # guest\agent\dist must hold the agent build (copy it from the main checkout).
$null = & $m { param($t) Read-GpuVMTemplate -Name $t } $Template
if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "A machine called '$Name' exists already." }
$freeGB = (Get-Counter '\Memory\Available MBytes').CounterSamples.CookedValue / 1024
if ($freeGB -lt $MemoryGB + 0.4) { throw ("{0:N1} GB free; a {1} GB copy needs about {2:N1}. Turn another machine off first." -f $freeGB, $MemoryGB, ($MemoryGB + 0.3)) }

$sw = [Diagnostics.Stopwatch]::StartNew()
$result = [ordered]@{ template = $Template; name = $Name; startedAt = (Get-Date).ToString('o'); ms = [ordered]@{} }
$made = $false

# As `agent`: one powershell command line, exactly as the MCP `run` tool sends it.
function Invoke-AsAgent([string]$Command, [int]$TimeoutSec = 60, [string]$Stdin = '') {
    $t = [Diagnostics.Stopwatch]::StartNew()
    $params = @{ file = 'powershell.exe'; args = @('-NoProfile', '-NonInteractive', '-Command', $Command); timeoutMs = $TimeoutSec * 1000 }
    if ($Stdin) { $params['stdin'] = $Stdin }
    $r = Invoke-GpuVMAgent -Name $Name -Method exec.run -Params $params -TimeoutSec ([math]::Min(600, $TimeoutSec + 20))
    $res = $r.result
    $stdout = if ($res -and $res.stdout) { [string]$res.stdout } elseif ($res -and $res.outputInBlob -and $r.blobPath) { [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($r.blobPath)) } else { '' }
    [ordered]@{
        command  = $Command
        ok       = [bool]$r.ok
        error    = $r.error
        exitCode = if ($res) { $res.exitCode } else { $null }
        timedOut = if ($res) { [bool]$res.timedOut } else { $null }
        ms       = $t.ElapsedMilliseconds
        # The tail is enough (winget draws progress bars).
        stdout   = (($stdout -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 12) -join "`n"
        stderr   = if ($res -and $res.stderr) { ([string]$res.stderr).Trim() } else { '' }
    }
}

try {
    Step "Creating the copy $Name of $Template ($MemoryGB GB)"
    $null = New-GpuVM -Name $Name -Template $Template -Disposable -Start -Override @{ vm = @{ memoryGB = $MemoryGB } }
    $made = [bool](Get-VM -Name $Name -ErrorAction SilentlyContinue)
    if ((Get-VM -Name $Name).State -ne 'Running') { throw "The copy didn't start (memory?)." }
    $state = & $m { param($n) Get-GpuVMState -Name $n } $Name
    $cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
    & $m { param($n, $c) Wait-GuestReady -Name $n -Credential $c | Out-Null } $Name $cred
    $result.ms['copyReady'] = $sw.ElapsedMilliseconds

    Step 'Install-GpuVMAgent (with winget)'
    $t = [Diagnostics.Stopwatch]::StartNew()
    $installed = Install-GpuVMAgent -Name $Name
    $result.ms['install'] = $t.ElapsedMilliseconds
    $result['winget'] = $installed['winget']
    $result['installSteps'] = $installed['ms']
    $result['restartedByInstall'] = $installed['restarted']
    if ($installed['winget'] -ne 'installed') { throw "winget wasn't installed: $($installed['winget'])" }

    Step 'Power cycle, as the template update does'
    $t = [Diagnostics.Stopwatch]::StartNew()
    if (-not $installed['restarted']) { & $m { param($n) Restart-GpuVMCold -Name $n } $Name }
    & $m { param($n, $c) Wait-GuestReady -Name $n -Credential $c | Out-Null } $Name $cred
    # The agent answers exec.run once `agent` is signed in and its helper is up.
    $deadline = (Get-Date).AddMinutes(5)
    do {
        $probe = try { Invoke-GpuVMAgent -Name $Name -Method exec.run -Params @{ file = 'cmd.exe'; args = @('/c', 'exit 0'); timeoutMs = 10000 } -TimeoutSec 20 } catch { $null }
        if ($probe -and $probe.ok) { break }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    if (-not ($probe -and $probe.ok)) { throw "The agent didn't answer within 5 minutes of the restart: $($probe.error)" }
    $result.ms['agentBack'] = $t.ElapsedMilliseconds

    Step 'As agent: winget'
    $checks = [ordered]@{}
    $checks['version'] = Invoke-AsAgent 'winget --version'
    # The first call may still be registering the package for `agent` (AppX at sign-in): retried for up to 2 minutes.
    $until = (Get-Date).AddMinutes(2)
    while ($checks['version'].exitCode -ne 0 -and (Get-Date) -lt $until) { Start-Sleep -Seconds 5; $checks['version'] = Invoke-AsAgent 'winget --version' }
    $result.ms['wingetAvailable'] = $sw.ElapsedMilliseconds
    $checks['whoami'] = Invoke-AsAgent 'whoami; whoami /groups | Select-String -SimpleMatch "Mandatory Label"'
    $checks['sources'] = Invoke-AsAgent 'winget source list --disable-interactivity'
    $checks['searchNoFlags'] = Invoke-AsAgent 'winget search --id Mozilla.Firefox -e' -TimeoutSec 120
    $checks['install'] = Invoke-AsAgent 'winget install --id Mozilla.Firefox -e --scope user --silent --accept-package-agreements --accept-source-agreements --disable-interactivity' -TimeoutSec 580
    $checks['firefox'] = Invoke-AsAgent '$p = @("$env:LOCALAPPDATA\Mozilla Firefox\firefox.exe", "$env:ProgramFiles\Mozilla Firefox\firefox.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1; if ($p) { $p; (Get-Item $p).VersionInfo.ProductVersion; (Get-AuthenticodeSignature $p).SignerCertificate.Subject } else { "missing"; exit 1 }'
    $checks['list'] = Invoke-AsAgent 'winget list --id Mozilla.Firefox -e --disable-interactivity --accept-source-agreements'
    $result['agent'] = $checks
    foreach ($k in $checks.Keys) { Step ("  {0,-14} exit {1,-5} {2,6} ms  {3}" -f $k, $checks[$k].exitCode, $checks[$k].ms, (($checks[$k].stdout -split "`n") | Select-Object -Last 1)) }

    Step 'Install-GpuVMAgent again (a copy of an updated template)'
    $t = [Diagnostics.Stopwatch]::StartNew()
    $again = Install-GpuVMAgent -Name $Name
    $result.ms['reinstall'] = $t.ElapsedMilliseconds
    $result['wingetAgain'] = $again['winget']
    $result['reinstallSteps'] = $again['ms']

    $result['guest'] = Invoke-Command -VMName $Name -Credential $cred -ScriptBlock {
        $p = Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'Microsoft.DesktopAppInstaller'
        [ordered]@{
            os          = [Environment]::OSVersion.Version.ToString()
            provisioned = @($p | ForEach-Object Version) -join ','
            perUser     = @(Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller | ForEach-Object { "$($_.Version): " + (@($_.PackageUserInformation | ForEach-Object { "$($_.UserSecurityId.Username)=$($_.InstallState)" }) -join ', ') })
            policies    = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller' -ErrorAction SilentlyContinue | Select-Object Enable* | ConvertTo-Json -Compress
            stamp       = if (Test-Path 'C:\ProgramData\GpuVM\Agent\winget') { Get-Content -Raw 'C:\ProgramData\GpuVM\Agent\winget' } else { $null }
        }
    }
    $pass = $checks['version'].exitCode -eq 0 -and $checks['install'].exitCode -eq 0 -and $checks['firefox'].exitCode -eq 0 -and
        -not $checks['searchNoFlags'].timedOut -and $result['wingetAgain'] -eq 'current' -and $checks['whoami'].stdout -match 'Medium'
    $result['pass'] = $pass
    Step $(if ($pass) { 'PASS' } else { 'FAIL: see the json' })
}
catch { $result['error'] = $_.Exception.Message; Step "ERROR: $($_.Exception.Message)" }
finally {
    $result.ms['total'] = $sw.ElapsedMilliseconds
    $file = Join-Path $out "$Label-$(Get-Date -Format yyyyMMdd-HHmmss).json"
    $result | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 $file
    Step "Saved $file"
    if ($made -and -not $Keep) {
        Step "Deleting $Name"
        try { Remove-GpuVMDisposable -Name $Name -Confirm:$false } catch { Write-Warning "Delete $Name by hand: $($_.Exception.Message)" }
    }
}
