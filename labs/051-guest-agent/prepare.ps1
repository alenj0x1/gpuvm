# Installs the guest agent in the lab VM the way the host broker will: builds it, makes the per-VM secret, copies the
# exe + install.ps1 over PowerShell Direct, runs install.ps1 -Secret, keeps the returned agent password with DPAPI
# (out\agent.xml) and restarts the VM so it signs in as `agent`. Also copies the lab harness for the guest-side probes
# to C:\ProgramData\GpuVMLab051 (removed by cleanup.ps1). Run elevated, with the lab lock held.
param([string]$Name = 'agent051', [switch]$NoRestart, [switch]$NoBuild)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null
$agentDir = Join-Path $root 'guest\agent'
$harnessDir = Join-Path $PSScriptRoot 'harness'
if (-not $NoBuild) {
    Push-Location $agentDir; cargo build --release; if ($LASTEXITCODE) { throw 'agent build failed' }; Pop-Location
    Push-Location $harnessDir; cargo build --release; if ($LASTEXITCODE) { throw 'harness build failed' }; Pop-Location
}
$exe = Join-Path $agentDir 'target\release\gpuvm-agent.exe'
$harness = Join-Path $harnessDir 'target\release\harness.exe'

# the secret: 32 random bytes, kept for the harness in out\ (git-ignored, deleted by cleanup.ps1)
$secretFile = Join-Path $out 'secret.bin'
if (-not (Test-Path $secretFile)) {
    $k = [byte[]]::new(32); [Security.Cryptography.RandomNumberGenerator]::Fill($k)
    [IO.File]::WriteAllBytes($secretFile, $k)
}
$secret = [IO.File]::ReadAllBytes($secretFile)

$cred = Import-Clixml (Join-Path $out 'guest.xml')
$s = New-PSSession -VMName $Name -Credential $cred
try {
    $setup = 'C:\Windows\Temp\gpuvm-agent-setup'
    Invoke-Command -Session $s { param($d) Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory $d | Out-Null } -ArgumentList $setup
    Copy-Item $exe -Destination $setup -ToSession $s
    # install.ps1 goes as a script block: guests keep the default execution policy (Restricted), which blocks .ps1
    # files but not commands sent over PowerShell Direct
    $install = [scriptblock]::Create((Get-Content (Join-Path $agentDir 'install.ps1') -Raw))
    $t = [Diagnostics.Stopwatch]::StartNew()
    try { $r = Invoke-Command -Session $s -ScriptBlock $install -ArgumentList $setup, $secret }
    finally { Invoke-Command -Session $s { param($d) Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } -ArgumentList $setup }
    $installMs = $t.ElapsedMilliseconds
    # the password goes straight to DPAPI; it is never printed
    [pscredential]::new('agent', (ConvertTo-SecureString $r.password -AsPlainText -Force)) | Export-Clixml (Join-Path $out 'agent.xml')
    [pscustomobject]@{ installMs = $installMs; version = $r.version; signInAs = $r.signInAs; secret = $r.secret; rebootNeeded = $r.rebootNeeded; notes = ($r.notes -join '; ') } | Format-List
    # guest-side lab probes (readable by Users, so the agent user can run guest-errorbox)
    Invoke-Command -Session $s { New-Item -ItemType Directory C:\ProgramData\GpuVMLab051 -Force | Out-Null }
    Copy-Item $harness -Destination 'C:\ProgramData\GpuVMLab051\harness.exe' -ToSession $s -Force
}
finally { Remove-PSSession $s }
if (-not $NoRestart) {
    # a clean restart from inside: Restart-VM -Force is a hard reset and lost the registry changes made seconds
    # before (service, Winlogon) while the files survived (first run of this lab)
    Invoke-Command -VMName $Name -Credential $cred { Restart-Computer -Force }
    'restarting'
}
