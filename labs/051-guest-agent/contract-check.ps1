# Installs guest/agent/dist in the lab VM exactly as the broker does (dist copied to the staging folder, install.ps1
# run with Invoke-Command -FilePath, staging as the only positional argument, the secret already in place), twice:
# the first run updates (full path), the second must take the fast path (new password, service restart). Prints
# the times and the returned fields except the password, which goes to out\agent.xml (DPAPI). Lab lock held by caller.
param([string]$Name = 'agent051', [int]$Runs = 2, [switch]$WithSecret)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$cred = Import-Clixml (Join-Path $PSScriptRoot 'out\guest.xml')
$staging = 'C:\ProgramData\GpuVM\Agent\staging'
# -WithSecret: pass out\secret.bin as -Secret (what a clone of agent-tpl needs: it has none)
$args2 = if ($WithSecret) { @($staging, [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'out\secret.bin'))) } else { @($staging) }
$s = New-PSSession -VMName $Name -Credential $cred
try {
    for ($i = 1; $i -le $Runs; $i++) {
        Invoke-Command -Session $s { param($d) New-Item -ItemType Directory $d -Force | Out-Null } -ArgumentList $staging
        Get-ChildItem (Join-Path $root 'guest\agent\dist') | ForEach-Object { Copy-Item $_.FullName -Destination $staging -ToSession $s -Force }
        $t = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Command -Session $s -FilePath (Join-Path $root 'guest\agent\install.ps1') -ArgumentList $args2
        $ms = $t.ElapsedMilliseconds
        [pscredential]::new('agent', (ConvertTo-SecureString $r.password -AsPlainText -Force)) | Export-Clixml (Join-Path $PSScriptRoot 'out\agent.xml')
        $left = Invoke-Command -Session $s { param($d) Test-Path $d } -ArgumentList $staging
        "run $i : $ms ms, version $($r.version), fastPath $($r.fastPath), secret $($r.secret), rebootNeeded $($r.rebootNeeded), password returned $([bool]$r.password), staging left $left"
    }
    Invoke-Command -Session $s { Get-Service GpuVMAgent | ForEach-Object Status; Get-Content C:\ProgramData\GpuVM\Agent\logs\agent.log -Tail 4 -Encoding UTF8 }
}
finally { Remove-PSSession $s }
