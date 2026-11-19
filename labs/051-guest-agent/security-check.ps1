# Checks the security review's fixes inside the lab VM (agent 0.3.0):
# - H2: a junction planted at C:\ProgramData\GpuVM\Agent\logs (pointing to a scratch folder) is removed by install.ps1
#   without following it, and the SYSTEM service logs into the real folder; the scratch folder stays untouched.
# - H1: a program running as the agent user (a one-shot interactive task as `agent`, i.e. what exec.run could start)
#   tries to open the session helper with dangerous and harmless rights.
# - M2: the backup key is readable by SYSTEM and Administrators only.
# Run elevated with the lab lock held; the VM is signed in as `agent`.
param([string]$Name = 'agent051')
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$cred = Import-Clixml (Join-Path $PSScriptRoot 'out\guest.xml')
$staging = 'C:\ProgramData\GpuVM\Agent\staging'
$s = New-PSSession -VMName $Name -Credential $cred
try {
    # H2 setup: a junction where the service writes its log
    Invoke-Command -Session $s {
        Stop-Service GpuVMAgent -Force
        New-Item -ItemType Directory C:\Lab051Target -Force | Out-Null
        Set-Content C:\Lab051Target\keep.txt 'untouched'
        Remove-Item C:\ProgramData\GpuVM\Agent\logs -Recurse -Force -ErrorAction SilentlyContinue
        & cmd.exe /c mklink /J C:\ProgramData\GpuVM\Agent\logs C:\Lab051Target | Out-Null
        New-Item -ItemType Directory $using:staging -Force | Out-Null
    }
    Get-ChildItem (Join-Path $root 'guest\agent\dist') | ForEach-Object { Copy-Item $_.FullName -Destination $staging -ToSession $s -Force }
    $r = Invoke-Command -Session $s -FilePath (Join-Path $root 'guest\agent\install.ps1') -ArgumentList $staging
    [pscredential]::new('agent', (ConvertTo-SecureString $r.password -AsPlainText -Force)) | Export-Clixml (Join-Path $PSScriptRoot 'out\agent.xml')
    "install: version $($r.version) fastPath $($r.fastPath) notes '$($r.notes -join '; ')'"
    Start-Sleep -Seconds 3
    Invoke-Command -Session $s {
        $l = Get-Item C:\ProgramData\GpuVM\Agent\logs -Force
        "logs is a link now: $([bool]($l.Attributes -band [IO.FileAttributes]::ReparsePoint)); target folder: $((Get-ChildItem C:\Lab051Target | ForEach-Object Name) -join ',')"
        "service log lines: $((Get-Content C:\ProgramData\GpuVM\Agent\logs\agent.log -ErrorAction SilentlyContinue).Count)"
        Remove-Item C:\Lab051Target -Recurse -Force
        $acl = Get-Acl 'HKLM:\SOFTWARE\GpuVM\Agent\Backup'
        "backup key ACL: $(($acl.Access | ForEach-Object { "$($_.IdentityReference)=$($_.RegistryRights)" }) -join '; ')"
    }
    # H1: open the helper as the agent user
    Copy-Item (Join-Path $PSScriptRoot 'harness\target\release\harness.exe') -Destination 'C:\Users\Public\lab051-harness.exe' -ToSession $s -Force
    Invoke-Command -Session $s {
        Remove-Item C:\Users\Public\lab051-open.json -ErrorAction SilentlyContinue
        $a = New-ScheduledTaskAction -Execute 'C:\Users\Public\lab051-harness.exe' -Argument 'guest-open-helper'
        $p = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\agent" -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName Lab051Open -Action $a -Principal $p -Force | Out-Null
        Start-ScheduledTask -TaskName Lab051Open
        $t = 0; while (-not (Test-Path C:\Users\Public\lab051-open.json) -and $t -lt 50) { Start-Sleep -Milliseconds 200; $t++ }
        Unregister-ScheduledTask -TaskName Lab051Open -Confirm:$false
        "as agent: $(Get-Content C:\Users\Public\lab051-open.json -ErrorAction SilentlyContinue)"
        Remove-Item C:\Users\Public\lab051-open.json, C:\Users\Public\lab051-harness.exe -ErrorAction SilentlyContinue
        Get-Content C:\ProgramData\GpuVM\Agent\logs\agent.log -Tail 3 -Encoding UTF8
    }
}
finally { Remove-PSSession $s }
