# Lab 016: templates on the real VM. Shuts the VM down, saves it as a template (timing and size), creates a VM on top
# of it (timing and size of the differencing disk), boots it and checks from inside: Sunshine got a new identity, the
# apps and cleanup level came along, and the pending computer rename is applied. The test VM is removed at the end;
# the template stays unless -RemoveTemplate. The source VM is started again. Run elevated:
#   pwsh -File labs/016-templates/run.ps1 -VMName win10
param(
    [string]$VMName = 'win10',
    [string]$Template = 'lab016-base',
    [string]$Clone = 'lab016-copia',
    [int]$CloneMemoryGB = 7,
    [switch]$RemoveTemplate,
    # Reuses a template made by an earlier run (copying a large disk takes a while).
    [switch]$UseExisting,
    [string]$Out = (Join-Path $PSScriptRoot 'out\result.txt')
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
Start-Transcript -Path $Out -Force | Out-Null
$m = Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force -PassThru
$identity = {
    $s = Get-Content 'C:\Program Files\Sunshine\config\sunshine_state.json' -Raw | ConvertFrom-Json
    [ordered]@{
        computer  = $env:COMPUTERNAME
        uniqueid  = if ($s.PSObject.Properties['root']) { [string]$s.root.uniqueid } else { '' }
        cert      = Test-Path 'C:\Program Files\Sunshine\config\credentials\cacert.pem'
        sunshine  = [string](Get-Service SunshineService -ErrorAction SilentlyContinue).Status
        telemetry = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -ErrorAction SilentlyContinue).AllowTelemetry
        vlc       = Test-Path "$env:ProgramFiles\VideoLAN\VLC\vlc.exe"
        gpu       = [string](Get-CimInstance Win32_VideoController | Where-Object Name -like '*NVIDIA*' | Select-Object -First 1).Status
    }
}
try {
    $cred = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $VMName
    if ((Get-VM $VMName).State -eq 'Running') {
        "source before: " + ((Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock $identity) | ConvertTo-Json -Compress)
    }
    $source = Get-VHD -Path (Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1).Path
    "source disk: $($source.VhdType), $([math]::Round($source.Size / 1GB)) GB, file $([math]::Round($source.FileSize / 1GB, 1)) GB"

    $t = [Diagnostics.Stopwatch]::StartNew()
    if (-not $UseExisting) { New-GpuVMTemplate -Name $Template -VMName $VMName -ShutdownIfRunning -Confirm:$false | Out-Null }
    # Only Administrators and SYSTEM may read templates; Hyper-V must still open the base disk for the copy.
    & $m { Protect-GpuVMSharedFolder -Path (Get-TemplateRoot) }
    "templates ACL: " + ((Get-Acl (& $m { Get-TemplateRoot })).Access | ForEach-Object { "$($_.IdentityReference)" }) -join ', '
    $tpl = Get-GpuVMTemplate | Where-Object { $_['name'] -eq $Template }
    "template: $([int]$t.Elapsed.TotalSeconds) s, file $($tpl['fileGB']) GB"

    # The source starts again at the end of New-GpuVMTemplate; both VMs don't fit in memory at once.
    Stop-VM -Name $VMName -Force
    $t.Restart()
    New-GpuVM -Name $Clone -Template $Template -Profile balanced -Override @{ vm = @{ memoryGB = $CloneMemoryGB } } | Out-Null
    $vhd = Get-VHD -Path (Get-VMHardDiskDrive -VMName $Clone | Select-Object -First 1).Path
    "clone: $([math]::Round($t.Elapsed.TotalSeconds, 1)) s, $($vhd.VhdType), file $([math]::Round($vhd.FileSize / 1MB)) MB, parent ok: $([IO.Path]::GetFullPath($vhd.ParentPath) -eq (& $m { param($n) (Read-GpuVMTemplate -Name $n)['vhdPath'] } $Template))"

    $t.Restart()
    Start-VM -Name $Clone
    & $m { param($n, $c) Wait-GuestReady -Name $n -Credential $c } $Clone $cred
    "clone boot to PowerShell Direct: $([int]$t.Elapsed.TotalSeconds) s"
    & $m { param($n, $c) Invoke-GuestPendingWork -Name $n -Credential $c } $Clone $cred
    Start-Sleep -Seconds 20
    "clone inside: " + ((Invoke-Command -VMName $Clone -Credential $cred -ScriptBlock $identity) | ConvertTo-Json -Compress)
    "clone state pendingRename: $((& $m { param($n) Get-GpuVMState -Name $n } $Clone)['pendingRename'])"
    "template in use by: $((Get-GpuVMTemplate | Where-Object { $_['name'] -eq $Template })['usedBy'] -join ', ')"
    "remove while in use refused: $(try { Remove-GpuVMTemplate -Name $Template -Confirm:$false; $false } catch { $true })"
    # The new computer name applies on restart; automatic sign-in must still work with it.
    $t.Restart()
    Restart-VM -Name $Clone -Force
    Start-Sleep -Seconds 15
    & $m { param($n, $c) Wait-GuestReady -Name $n -Credential $c } $Clone $cred
    Start-Sleep -Seconds 30
    "after restart ($([int]$t.Elapsed.TotalSeconds) s): " + ((Invoke-Command -VMName $Clone -Credential $cred -ScriptBlock {
        [ordered]@{ computer = $env:COMPUTERNAME; signedIn = [string](Get-CimInstance Win32_ComputerSystem).UserName; explorer = [bool](Get-Process explorer -ErrorAction SilentlyContinue) }
    }) | ConvertTo-Json -Compress)
    $vhd = Get-VHD -Path $vhd.Path
    "clone disk after first boot: $([math]::Round($vhd.FileSize / 1GB, 2)) GB"
    "templates: " + ((Get-GpuVMTemplate) | ConvertTo-Json -Compress -Depth 4)
}
catch { "ERROR: $($_.Exception.Message)"; $_.ScriptStackTrace }
finally {
    if (Get-VM -Name $Clone -ErrorAction SilentlyContinue) {
        Remove-GpuVM -Name $Clone -DeleteDisk -Confirm:$false | Out-Null
        'test VM removed'
    }
    if ($RemoveTemplate -and (Get-GpuVMTemplate | Where-Object { $_['name'] -eq $Template })) {
        Remove-GpuVMTemplate -Name $Template -Confirm:$false
        'template removed'
    }
    if ((Get-VM $VMName).State -eq 'Off') { Start-VM -Name $VMName; "$VMName started again" }
    Stop-Transcript | Out-Null
}
