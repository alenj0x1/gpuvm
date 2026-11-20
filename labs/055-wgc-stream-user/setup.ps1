# Lab 055: one agent copy of agent-tpl, prepared the way an open does (Install-GpuVMAgent: agent, cold boot, sign-in
# as `agent`). The copy stays for the other scripts of this lab; -Remove deletes it. Run elevated.
param([string]$Template = 'agent-tpl', [string]$Name = 'agent055', [switch]$Remove)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
function Line($what) { Write-Host "$(Get-Date -Format HH:mm:ss.fff) $what" }
Import-Module (Join-Path $root 'src\GpuVM\GpuVM.psd1') -Force
$m = Get-Module GpuVM
$installed = Join-Path $env:ProgramFiles 'GpuVM\gpuvm'
& $m {
    param($viewer, $dist)
    $script:LabViewer = $viewer; $script:LabDist = $dist
    function script:Get-GpuVMViewerPath { $script:LabViewer }
    function script:Get-RepoPath { param($Relative) if ($Relative -eq 'guest\agent') { $script:LabDist } else { Join-Path $script:RepoRoot $Relative } }
} (Join-Path $installed 'viewer\GpuVMViewer.exe') (Join-Path $installed 'guest\agent')
if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
    Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue
    Remove-GpuVM -Name $Name -DeleteDisk -Confirm:$false
    Line 'old copy removed'
}
if ($Remove) { return }
$sw = [Diagnostics.Stopwatch]::StartNew()
New-GpuVM -Name $Name -Template $Template | Out-Null
Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes 4GB
Start-VM -Name $Name
$state = & $m { param($n) Get-GpuVMState -Name $n } $Name
$cred = & $m { param($s) Get-GpuVMGuestCredential -State $s } $state
& $m { param($n, $c) Wait-GuestReady -Name $n -Credential $c } $Name $cred
Line "guest ready at $([int]$sw.Elapsed.TotalSeconds) s"
$install = Install-GpuVMAgent -Name $Name
Line "install at $([int]$sw.Elapsed.TotalSeconds) s: $($install | ConvertTo-Json -Compress -Depth 4)"
# The agent's own session after the cold boot.
$deadline = (Get-Date).AddMinutes(6)
do {
    Start-Sleep -Seconds 5
    $who = try { Invoke-Command -VMName $Name -Credential $cred { (quser 2>$null) -join ' | ' } -ErrorAction Stop } catch { $null }
} while ((Get-Date) -lt $deadline -and "$who" -notmatch 'agent')
Line "sessions: $who ($([int]$sw.Elapsed.TotalSeconds) s)"
