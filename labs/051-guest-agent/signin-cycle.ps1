# On a FRESH lab VM: installs the agent the broker's way and checks the automatic sign-in with real restarts:
# agent -> the person again (-SignInAs previous) -> agent, timing each sign-in. This is what install-cycle.ps1 could
# not prove (it only compared registry values and which LSA secrets exist). Run elevated with the lab lock held.
param([string]$Name = 'agent051')
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'
$cred = Import-Clixml (Join-Path $out 'guest.xml')
$install = Join-Path $root 'guest\agent\install.ps1'
$staging = 'C:\ProgramData\GpuVM\Agent\staging'
$secretFile = Join-Path $out 'secret.bin'
if (-not (Test-Path $secretFile)) { $k = [byte[]]::new(32); [Security.Cryptography.RandomNumberGenerator]::Fill($k); [IO.File]::WriteAllBytes($secretFile, $k) }
$secret = [IO.File]::ReadAllBytes($secretFile)

function Wait-User([string]$Who) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 2
        $u = try { Invoke-Command -VMName $Name -Credential $cred -ErrorAction Stop { (Get-CimInstance Win32_ComputerSystem).UserName } } catch { $null }
    } until (($u -like "*\$Who") -or $sw.Elapsed.TotalMinutes -gt 4)
    if ($u -notlike "*\$Who") { throw "after 4 min the signed-in user is '$u', not $Who" }
    "  signed in as $u, $([int]$sw.Elapsed.TotalSeconds) s after the restart call"
}
function Install([object[]]$ArgList) {
    $s = New-PSSession -VMName $Name -Credential $cred
    try {
        Invoke-Command -Session $s { param($d) New-Item -ItemType Directory $d -Force | Out-Null } -ArgumentList $staging
        Get-ChildItem (Join-Path $root 'guest\agent\dist') | ForEach-Object { Copy-Item $_.FullName -Destination $staging -ToSession $s -Force }
        $t = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Command -Session $s -FilePath $install -ArgumentList $ArgList
        if ($r.password) { [pscredential]::new('agent', (ConvertTo-SecureString $r.password -AsPlainText -Force)) | Export-Clixml (Join-Path $out 'agent.xml') }
        "  install $($t.ElapsedMilliseconds) ms: version $($r.version) fastPath $($r.fastPath) signInAs $($r.signInAs) rebootNeeded $($r.rebootNeeded) notes '$($r.notes -join '; ')'"
    }
    finally { Remove-PSSession $s }
}
function Restart-Guest { Invoke-Command -VMName $Name -Credential $cred { Restart-Computer -Force } }

'1. before: who signs in, and is the person''s autologon password an LSA secret?'
Invoke-Command -VMName $Name -Credential $cred {
    $w = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    "  AutoAdminLogon=$($w.AutoAdminLogon) DefaultUserName=$($w.DefaultUserName) plain DefaultPassword=$([bool]($w.PSObject.Properties.Name -contains 'DefaultPassword'))"
}
'2. install, restart -> agent'
Install @($staging, $secret)
Restart-Guest; Wait-User 'agent'
'3. -SignInAs previous, restart -> the person'
Install @($staging, $null, 'previous')
Restart-Guest; Wait-User 'gpuvm'
'4. -SignInAs agent again, restart -> agent'
Install @($staging, $secret, 'agent')
Restart-Guest; Wait-User 'agent'
Invoke-Command -VMName $Name -Credential $cred { "  profile: $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' | Where-Object ProfileImagePath -like '*agent*').ProfileImagePath)" }
