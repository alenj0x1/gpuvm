# Rebuilds the agent user in the lab VM from scratch (its profile had ended up at C:\Users\agent.000 after the first
# run's hard reset): signs in as the previous user, removes the agent user and both profile folders (rmdir, which
# never follows the lab's junctions), installs guest/agent/dist again with out\secret.bin and restarts into `agent`.
# Run elevated with the lab lock held.
param([string]$Name = 'agent051')
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$cred = Import-Clixml (Join-Path $PSScriptRoot 'out\guest.xml')
$install = Join-Path $root 'guest\agent\install.ps1'
$staging = 'C:\ProgramData\GpuVM\Agent\staging'
$secret = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'out\secret.bin'))
function Wait-User([string]$Who) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 3
        $u = try { Invoke-Command -VMName $Name -Credential $cred -ErrorAction Stop { (Get-CimInstance Win32_ComputerSystem).UserName } } catch { $null }
    } until (($u -like "*\$Who") -or $sw.Elapsed.TotalMinutes -gt 5)
    "signed in: $u after $([int]$sw.Elapsed.TotalSeconds) s"
}
function Copy-Dist {
    $s = New-PSSession -VMName $Name -Credential $cred
    Invoke-Command -Session $s { param($d) New-Item -ItemType Directory $d -Force | Out-Null } -ArgumentList $staging
    Get-ChildItem (Join-Path $root 'guest\agent\dist') | ForEach-Object { Copy-Item $_.FullName -Destination $staging -ToSession $s -Force }
    Remove-PSSession $s
}
Copy-Dist
$r = Invoke-Command -VMName $Name -Credential $cred -FilePath $install -ArgumentList $staging, $null, 'previous'
"previous: rebootNeeded $($r.rebootNeeded)"
Invoke-Command -VMName $Name -Credential $cred { Restart-Computer -Force }
Wait-User 'gpuvm'
Invoke-Command -VMName $Name -Credential $cred {
    $u = Get-LocalUser agent -ErrorAction SilentlyContinue
    if ($u) {
        Get-CimInstance Win32_UserProfile | Where-Object SID -eq $u.SID.Value | Remove-CimInstance
        Remove-LocalUser agent
    }
    foreach ($d in Get-ChildItem C:\Users -Directory -Force | Where-Object Name -like 'agent*') { & cmd.exe /c rmdir /s /q "$($d.FullName)" }
    "users folder: $((Get-ChildItem C:\Users -Directory -Force | ForEach-Object Name) -join ', '); gpuvm profile intact: $(Test-Path C:\Users\gpuvm\NTUSER.DAT)"
}
Copy-Dist
$r = Invoke-Command -VMName $Name -Credential $cred -FilePath $install -ArgumentList $staging, $secret
[pscredential]::new('agent', (ConvertTo-SecureString $r.password -AsPlainText -Force)) | Export-Clixml (Join-Path $PSScriptRoot 'out\agent.xml')
"install: version $($r.version) fastPath $($r.fastPath) notes '$($r.notes -join '; ')'"
Invoke-Command -VMName $Name -Credential $cred { Restart-Computer -Force }
Wait-User 'agent'
Invoke-Command -VMName $Name -Credential $cred { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' | Where-Object ProfileImagePath -like '*agent*').ProfileImagePath }
