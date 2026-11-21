function New-GpuVMTemplate {
    <#
    .SYNOPSIS
    Saves a stopped VM's Windows as a template: a read-only base disk that new VMs build on (New-GpuVM -Template).
    The VM stays as it is. The template keeps its apps, cleanup level, Sunshine credentials and Windows password.
    .EXAMPLE
    New-GpuVMTemplate -Name juegos-base -VMName win10
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Name,
        [Parameter(Mandatory)][string]$VMName,
        # Shuts the VM down cleanly first and starts it again when the copy is done.
        [switch]$ShutdownIfRunning
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $VMName
    Assert-GpuVMNotDisposable -State $state -Action 'be saved as a template'
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $wasRunning = $vm.State -eq 'Running'
    if ($vm.State -ne 'Off' -and -not ($wasRunning -and $ShutdownIfRunning)) { throw "Turn off the VM '$VMName' before creating the template." }
    $source = (Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1).Path
    if (-not $source) { throw "The VM '$VMName' has no disk." }
    $dir = Get-TemplateDirectory -Name $Name
    if (Test-Path -LiteralPath $dir) { throw "There's already a template called '$Name'." }
    $sourceVhd = Get-VHD -Path $source
    # A dynamic copy only takes the space Windows uses; it needs at most that much free on the PC. A VM built on a
    # template is merged with its parents, so the whole chain counts.
    $chainBytes = 0
    $link = $sourceVhd
    for ($i = 0; $link -and $i -lt 16; $i++) {
        $chainBytes += $link.FileSize
        $link = if ($link.ParentPath) { Get-VHD -Path $link.ParentPath -ErrorAction SilentlyContinue }
    }
    $needGB = [math]::Ceiling($chainBytes / 1GB) + 10
    $freeGB = Get-DriveFreeGB (Get-GpuVMDefaultRoot)
    if ($needGB -gt $freeGB) { throw "There's no room for the template: about $needGB GB are needed and $freeGB GB are free." }
    if (-not $PSCmdlet.ShouldProcess($Name, "Create template from $VMName")) { return }
    if ($wasRunning) {
        Write-Step 'Shutting down'
        Stop-VM -Name $VMName -Force
    }

    Initialize-GpuVMRoot -Path (Get-GpuVMDefaultRoot)
    New-Item -ItemType Directory -Path (Get-TemplateRoot) -Force | Out-Null
    Protect-GpuVMSharedFolder -Path (Get-TemplateRoot)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $target = Join-Path $dir "$Name.vhdx"
    try {
        Write-Step "Copying the disk of $VMName (it may take a few minutes)"
        # Convert-VHD copies into a new dynamic disk; a disk that is itself a copy of a template is merged into one.
        Convert-VHD -Path $source -DestinationPath $target -VHDType Dynamic -ErrorAction Stop
        # A template never carries the VM's agent secret (every copy would share it): removed from the copy, before
        # its unused space is given back.
        # What agent and Sunshine it carries, so GpuVM can tell when a newer build makes it stale (Update-GpuVMTemplate).
        $stampKeys = @((Get-BundledComponentStamp).Keys)
        $components = Invoke-WithMountedWindows -Path $target -ScriptBlock {
            param($root)
            Remove-GuestAgentSecret -WindowsRoot $root
            if ($stampKeys) { Get-GuestComponentStamp -WindowsRoot $root -Keys $stampKeys }
        }
        # Only what Windows uses now: the space of deleted files is given back (lab 045).
        Compress-GpuVMDiskCopy -Path $target | Out-Null
        (Get-Item -LiteralPath $target).IsReadOnly = $true

        $streaming = $null
        if ($state['streaming']) {
            $streaming = [ordered]@{}
            foreach ($key in $state['streaming'].Keys) { if ($key -notin 'pairedClient', 'pairedAt') { $streaming[$key] = $state['streaming'][$key] } }
        }
        $vhd = Get-VHD -Path $target
        Write-JsonFile -Path (Join-Path $dir 'template.json') -Data ([ordered]@{
                fromVM    = $VMName
                createdAt = (Get-Date).ToString('o')
                edition   = $state['edition']
                sizeGB    = [math]::Round($vhd.Size / 1GB)
                config    = $state['config']
                gpu       = $state['gpu']
                streaming = $streaming
                guest     = $state['guest']
                # Apps chosen for the VM but not installed yet (it was never opened): its copies install them.
                pendingApps = @(if ($state.Contains('pendingApps')) { $state['pendingApps'] })
                # Apps already in its Windows: its copies show them as installed before their first check.
                installedApps = @(if ($state.Contains('installedApps')) { $state['installedApps'] })
                # A template of an agent machine makes agent machines: isolated, Sunshine as a service, its agent
                # installed (with its own secret) the first time each copy is opened or claimed.
                use           = (Get-TemplateAgentUse -State $state)['use']
                agentSignInAs = (Get-TemplateAgentUse -State $state)['agentSignInAs']
                layers        = @("$Name.vhdx")
                components    = $components
            })
    }
    catch {
        if (Test-Path -LiteralPath $target) { (Get-Item -LiteralPath $target).IsReadOnly = $false }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    finally {
        if ($wasRunning) {
            Write-Step 'Starting'
            try { Start-VM -Name $VMName -ErrorAction Stop } catch { Write-Warning "Couldn't turn ${VMName} back on: $($_.Exception.Message)" }
        }
    }
    Write-Step "Template '$Name' is ready ($([math]::Round((Get-Item -LiteralPath $target).Length / 1GB, 1)) GB)"
    Get-GpuVMTemplate | Where-Object { $_['name'] -eq $Name }
}

# What a template records about its source's use: an agent machine's template makes agent machines.
function Get-TemplateAgentUse {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    if ([string]$State['use'] -ne 'agent') { return @{ use = $null; agentSignInAs = $null } }
    $signIn = if ($State['agent'] -is [System.Collections.IDictionary] -and [string]$State['agent']['signInAs'] -eq 'own') { 'own' } else { 'agent' }
    @{ use = 'agent'; agentSignInAs = $signIn }
}
