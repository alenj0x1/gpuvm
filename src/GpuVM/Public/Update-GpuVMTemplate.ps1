function Update-GpuVMTemplate {
    <#
    .SYNOPSIS
    Brings a template up to this GpuVM's Sunshine (and agent, for an agent template), as a new layer on top of it, so
    its copies don't install them one by one (an agent copy: under a minute instead of ~5, lab 053 parts 6-7).

    .DESCRIPTION
    A temporary copy of the template gets the exact install every copy would otherwise get (GpuVM's Sunshine fork and
    its capture; for an agent template Install-GpuVMAgent, which brings the fork too), is turned off cleanly and its
    disk becomes the template's newest layer: a read-only differencing disk on the one before, without the agent's
    secret or Sunshine's identity. New copies sit on it; copies made before keep the layer they were made on,
    untouched. The app runs it with -Stale at its start and every hour; a template that is current is left alone,
    and one whose update failed is tried again a day later (or at once with -Name).
    .EXAMPLE
    Update-GpuVMTemplate -Name agent-tpl
    .EXAMPLE
    Update-GpuVMTemplate -Stale
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidatePattern('^[\w-]{1,40}$')][string]$Name,
        # Every template that is stale.
        [switch]$Stale,
        # Even when it is current.
        [switch]$Force
    )
    Assert-Admin
    if (-not $Name -and -not $Stale) { throw 'Name a template, or use -Stale for every template that needs it.' }
    $names = if ($Name) { @($Name) } else {
        $root = Get-TemplateRoot
        @(if (Test-Path -LiteralPath $root) { Get-ChildItem -LiteralPath $root -Directory | Where-Object Name -match '^[\w-]{1,40}$' | ForEach-Object Name })
    }
    $bundled = Get-BundledComponentStamp
    foreach ($n in $names) {
        $meta = try { Read-GpuVMTemplate -Name $n } catch { if ($Name) { throw }; Write-Warning $_.Exception.Message; continue }
        if (-not (Get-TemplateComponentKeys -Template $meta -Bundled $bundled)) {
            if ($Name) { throw "'$n' has neither streaming nor an agent: there's nothing of GpuVM's in it to update." }
            continue
        }
        if (-not $Force -and -not (Test-GpuVMTemplateStale -Template $meta -Bundled $bundled)) {
            if ($Name) { Write-Step "The template '$n' already has this GpuVM's Sunshine$(if ([string]$meta['use'] -eq 'agent') { ' and agent' })." }
            continue
        }
        # An update that failed isn't retried every hour (it would boot a copy for nothing): a day later, or when named.
        $failed = Get-TemplateUpdateFailure -Template $meta
        if (-not $Name -and -not $Force -and $failed -and $failed['at'] -gt (Get-Date).ToUniversalTime().AddDays(-1)) { continue }
        if (Test-TemplateUpdating -Template $meta) { Write-Warning "The template '$n' is already being updated."; continue }
        if (-not $PSCmdlet.ShouldProcess($n, 'Add a layer with this GpuVM''s Sunshine and agent')) { continue }
        Add-TemplateLayer -Template $meta -Bundled $bundled
    }
}

# <template>\update-failed.json: when and why the last update failed ({at (UTC), message}), or $null.
function Get-TemplateUpdateFailure {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Template)
    $path = Join-Path $Template['dir'] 'update-failed.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $data = try { Read-JsonFile $path } catch { return $null }
    $at = $data['at']
    $at = if ($at -is [datetime]) { $at.ToUniversalTime() } else {
        try { [datetime]::Parse([string]$at, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { return $null }
    }
    @{ at = $at; message = [string]$data['message'] }
}

# The update itself (see Update-GpuVMTemplate). Returns {name, layer, layers, ms}.
function Add-TemplateLayer {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Template, [System.Collections.IDictionary]$Bundled)
    $ErrorActionPreference = 'Stop'
    $n = $Template['name']
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $copy = ("$n" + '-update') -replace '^(.{40}).*$', '$1'
    $run = [guid]::NewGuid().ToString('n')
    $marker = Get-TemplateUpdateMarker -Template $Template
    $failedPath = Join-Path $Template['dir'] 'update-failed.json'
    $index = $Template['layerPaths'].Count
    $layerName = "$n.$index.vhdx"
    $layer = Join-Path $Template['dir'] $layerName
    # Hyper-V only opens a disk whose name ends in .vhdx.
    $building = Join-Path $Template['dir'] "$n.$index.building.vhdx"
    $metaPath = Join-Path $Template['dir'] 'template.json'
    # Only one update per template: the marker is created, never overwritten (a second run stops here).
    try {
        $stream = [IO.File]::Open($marker, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes((([ordered]@{ pid = $PID; startedAt = (Get-Date).ToUniversalTime().ToString('o'); copy = $copy; run = $run }) | ConvertTo-Json))
            $stream.Write($bytes, 0, $bytes.Length)
        }
        finally { $stream.Dispose() }
    }
    catch {
        # PowerShell wraps the IOException of an existing file; anything else (no folder, no rights) stops here.
        if (-not (Test-Path -LiteralPath $marker)) { throw }
        if (Test-TemplateUpdating -Template $Template) { throw "The template '$n' is already being updated." }
        # Left by a run that died: taken over.
        Write-JsonFile -Path $marker -Data ([ordered]@{ pid = $PID; startedAt = (Get-Date).ToUniversalTime().ToString('o'); copy = $copy; run = $run })
    }
    $created = $false
    try {
        # A layer file the template doesn't list, that no machine sits on: left by a run that died before recording it.
        if (Test-Path -LiteralPath $layer) {
            if (@(Get-TemplateChildVM -VhdPath $layer).Count) { throw "The template '$n' has a disk $layerName that it doesn't list and a machine uses; GpuVM leaves it alone." }
            (Get-Item -LiteralPath $layer).IsReadOnly = $false
            Remove-Item -LiteralPath $layer -Force
        }
        # The account the copy is opened with, before anything is made.
        if (-not (Get-GpuVMGuestCredential -State $Template)) { throw "GpuVM doesn't know the Windows account of the template '$n', so it can't update it." }
        # Left over from an update that died: only a machine this kind of run marked as its own copy of this template.
        if (Get-VM -Name $copy -ErrorAction SilentlyContinue) {
            $old = try { Get-GpuVMState -Name $copy } catch { $null }
            $mark = if ($old) { $old['templateUpdate'] }
            if (-not ($mark -is [System.Collections.IDictionary]) -or [string]$mark['template'] -ne $n) {
                throw "A machine called '$copy' exists and isn't an update of '$n'; rename it so the template can be updated."
            }
            Remove-GpuVM -Name $copy -DeleteDisk -Confirm:$false
        }
        if (Test-Path -LiteralPath $building) { Remove-Item -LiteralPath $building -Force }
        Write-Step "Updating the template '$n' with this GpuVM's Sunshine$(if ([string]$Template['use'] -eq 'agent') { ' and agent' }) (a temporary copy, a few minutes)"
        $null = New-GpuVMFromTemplate -Name $copy -Template $n
        $created = $true
        $state = Get-GpuVMState -Name $copy
        $state['templateUpdate'] = [ordered]@{ template = $n; run = $run }
        Save-GpuVMState $state
        Start-VM -Name $copy
        $credential = Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $copy)
        if ([string]$Template['use'] -eq 'agent') {
            # The agent's install brings GpuVM's Sunshine and its settings with it (Initialize-GuestStreamingForAgent);
            # a setup that only half worked isn't kept as the template's.
            $signIn = if ([string]$Template['agentSignInAs'] -eq 'own') { 'own' } else { 'agent' }
            $installed = Install-GpuVMAgent -Name $copy -User $signIn
            if ($installed['streaming'] -eq 'failed') { throw "Sunshine's setup in the temporary copy didn't finish; the template stays as it was." }
            # An agent template without the virtual display skips that setup: the fork still goes in.
            $streams = $Template['streaming'] -is [System.Collections.IDictionary] -and [string]$Template['streaming']['provider'] -eq 'sunshine'
            if ($streams -and $installed['streaming'] -ne 'ready') { $null = Install-GuestSunshineCapture -Name $copy -Credential $credential }
        }
        else {
            $sw2 = [Diagnostics.Stopwatch]::StartNew()
            Wait-GuestReady -Name $copy -Credential $credential | Out-Null
            $null = Install-GuestSunshineCapture -Name $copy -Credential $credential
            $null = Set-GuestCaptureMode -Name $copy -Credential $credential
            $installed = @{ restarted = $false; ms = @{ total = $sw2.ElapsedMilliseconds } }
        }
        # The controllers' driver (ViGEmBus) too: every copy's first open installed it and restarted Sunshine for it,
        # ~30 s of its "Preparing" (2026-11-21: 79 s first open of a copy).
        $streams = $Template['streaming'] -is [System.Collections.IDictionary] -and [string]$Template['streaming']['provider'] -eq 'sunshine'
        if ($streams) { $null = Install-GuestGamepad -Name $copy -Credential $credential }
        # Right after the install Windows shuts down but the machine never turns off (lab 053 part 6: the guest logs
        # its shutdown 3 s in, Hyper-V waits 90 s and turns it off). After one more boot it shuts down in seconds, and
        # only a clean shutdown makes a layer worth copying.
        if (-not $installed['restarted']) { Restart-GpuVMCold -Name $copy }
        Wait-GuestReady -Name $copy -Credential $credential | Out-Null
        # Read and cleaned inside the copy: this PC never mounts a disk the copy wrote.
        $keys = @(Get-TemplateComponentKeys -Template $Template -Bundled $Bundled)
        $components = Clear-GuestIdentityForLayer -Name $copy -Credential $credential -Keys $keys
        foreach ($key in $keys) {
            if ([string]$components[$key] -ne [string]$Bundled[$key]) { throw "The temporary copy doesn't have this GpuVM's $(Split-Path $key -Leaf); the template stays as it was." }
        }
        Write-Step 'Shutting the temporary copy down'
        if (-not (Stop-GuestCleanly -Name $copy)) {
            throw "Windows in the temporary copy '$copy' didn't shut down cleanly; the template stays as it was."
        }
        $timing = [ordered]@{ install = $installed['ms']['total']; ready = $sw.ElapsedMilliseconds }

        # Its disk becomes the layer: out of the copy's folder first, then the copy goes (with its agent registration).
        $disk = (Get-VMHardDiskDrive -VMName $copy | Select-Object -First 1).Path
        if (-not $disk -or [IO.Path]::GetFullPath((Get-VHD -Path $disk).ParentPath) -ne [IO.Path]::GetFullPath($Template['vhdPath'])) {
            throw "The temporary copy's disk isn't on the template's newest layer; the template stays as it was."
        }
        Move-Item -LiteralPath $disk -Destination $building
        Remove-GpuVM -Name $copy -DeleteDisk -Confirm:$false
        $created = $false
        # The template folder's permissions (Administrators and SYSTEM), not the copy's (it carried the VM's own access).
        & icacls.exe $building /reset /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Couldn't set the permissions of $building." }
        Move-Item -LiteralPath $building -Destination $layer
        (Get-Item -LiteralPath $layer).IsReadOnly = $true

        $data = Read-JsonFile $metaPath
        $data['layers'] = @($Template['layerPaths'] | ForEach-Object { Split-Path $_ -Leaf }) + $layerName
        $data['components'] = $components
        if ($streams) { $data['gamepad'] = 'vigembus' }
        $data['updatedAt'] = (Get-Date).ToString('o')
        Write-JsonFile -Path $metaPath -Data $data
        Remove-Item -LiteralPath $failedPath -Force -ErrorAction SilentlyContinue
        $timing['total'] = $sw.ElapsedMilliseconds
        Write-Step "Template '$n' is up to date (layer $index, $([math]::Round((Get-Item -LiteralPath $layer).Length / 1MB)) MB)"
        [ordered]@{ name = $n; layer = $layerName; layers = $index + 1; ms = $timing }
    }
    catch {
        $message = $_.Exception.Message
        # Written but not recorded (template.json is swapped in whole, so it either lists it or not): not the template's.
        $listed = try { @((Read-JsonFile $metaPath)['layers']) -contains $layerName } catch { $false }
        if ((Test-Path -LiteralPath $layer) -and -not $listed) {
            (Get-Item -LiteralPath $layer).IsReadOnly = $false
            Remove-Item -LiteralPath $layer -Force -ErrorAction SilentlyContinue
        }
        try { Write-JsonFile -Path $failedPath -Data ([ordered]@{ at = (Get-Date).ToUniversalTime().ToString('o'); message = $message }) } catch { }
        throw
    }
    finally {
        # Only the copy this run made (by its mark): never another machine with the same name.
        if ($created -and (Get-VM -Name $copy -ErrorAction SilentlyContinue)) {
            $mine = try { [string](Get-GpuVMState -Name $copy)['templateUpdate']['run'] -eq $run } catch { $false }
            if ($mine) {
                try { Remove-GpuVM -Name $copy -DeleteDisk -Confirm:$false } catch { Write-Warning "The temporary copy '$copy' couldn't be deleted: $($_.Exception.Message)" }
            }
        }
        if (Test-Path -LiteralPath $building) {
            # Never a new error here: it would hide the one that brought us here.
            try {
                $vhd = Get-VHD -Path $building -ErrorAction SilentlyContinue
                if ($vhd -and $vhd.Attached) { Dismount-VHD -Path $building -ErrorAction SilentlyContinue }
                Remove-Item -LiteralPath $building -Force -ErrorAction SilentlyContinue
            }
            catch { Write-Warning "$building couldn't be deleted: $($_.Exception.Message)" }
        }
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    }
}

# Inside the temporary copy, right before it shuts down: Sunshine and the agent stop (so neither writes again), the
# copy's Sunshine identity and paired devices, the agent's secret, logs and staging go (each copy of the template
# makes its own), and the hashes of this build's files are read. Returns {key: SHA-256 or $null}. Links inside the
# guest only lead to the guest's own files: nothing here touches this PC's.
function Clear-GuestIdentityForLayer {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][pscredential]$Credential, [string[]]$Keys = @())
    Write-Step 'Removing the temporary copy''s own identity'
    $result = Invoke-Command -VMName $Name -Credential $Credential -ErrorAction Stop -ArgumentList (, $Keys) -ScriptBlock {
        param($keys)
        $ErrorActionPreference = 'Stop'
        foreach ($service in 'GpuVMAgent', 'SunshineService') {
            Get-Service -Name $service -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        }
        $config = Join-Path $env:ProgramFiles 'Sunshine\config'
        $statePath = Join-Path $config 'sunshine_state.json'
        if (Test-Path -LiteralPath $statePath) {
            $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
            if ($state.PSObject.Properties['root']) { $state.PSObject.Properties.Remove('root') }
            [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 10))
        }
        foreach ($pem in 'cacert.pem', 'cakey.pem') {
            $path = Join-Path $config "credentials\$pem"
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
        $agent = Join-Path $env:ProgramData 'GpuVM\Agent'
        if (Test-Path -LiteralPath $agent) {
            Get-ChildItem -LiteralPath $agent -Force | Where-Object { $_.Name -eq 'secret' -or $_.Name -like '*.log' -or $_.Name -eq 'staging' } |
                Remove-Item -Recurse -Force
        }
        $stamp = @{}
        foreach ($key in $keys) {
            $path = Join-Path "$env:SystemDrive\" $key
            $stamp[$key] = if (Test-Path -LiteralPath $path -PathType Leaf) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
        }
        $stamp
    }
    # Only the keys asked for, as text: nothing else the guest sends back is kept.
    $components = [ordered]@{}
    foreach ($key in $Keys) {
        $hash = [string]$result[$key]
        $components[$key] = if ($hash -match '^[0-9A-F]{64}$') { $hash } else { $null }
    }
    $components
}

# Asks Windows to shut down and waits for the machine to be off: $true when it was, $false when it had to be turned
# off (then the disk may not be clean).
function Stop-GuestCleanly {
    param([Parameter(Mandatory)][string]$Name, [int]$TimeoutSec = 120)
    if ((Get-VM -Name $Name).State -eq 'Off') { return $true }
    $job = Stop-VM -Name $Name -Force -AsJob
    try {
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-VM -Name $Name).State -ne 'Off' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
        if ((Get-VM -Name $Name).State -eq 'Off') { return $true }
        Write-Warning "Windows in '$Name' didn't shut down in $TimeoutSec s; it is turned off."
        Stop-GpuVMBounded -Name $Name -ShutdownTimeoutSec 0 -TurnOffTimeoutSec 30
        $false
    }
    finally {
        # As Stop-GpuVMBounded: a Hyper-V job is only removed once it finished (lab 052).
        $job | Wait-Job -Timeout 15 -ErrorAction SilentlyContinue | Out-Null
        $job | Where-Object { $_.State -in 'Completed', 'Failed', 'Stopped' } | Remove-Job -Force -ErrorAction SilentlyContinue
    }
}
