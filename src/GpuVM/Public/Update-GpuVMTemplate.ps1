function Update-GpuVMTemplate {
    <#
    .SYNOPSIS
    Brings an agent template up to this GpuVM's agent and Sunshine, as a new layer on top of it, so its copies take
    the fast path again (~30 s instead of ~5 min, lab 053 part 6).

    .DESCRIPTION
    A temporary copy of the template gets the exact install every copy would otherwise get (Install-GpuVMAgent: the
    agent, GpuVM's Sunshine fork and its settings), is turned off cleanly and its disk becomes the template's newest
    layer: a read-only differencing disk on the one before, without the agent's secret or Sunshine's identity. New
    copies sit on it; copies made before keep the layer they were made on, untouched. GpuVM's service runs it with
    -Stale at its start and every hour; a template that is current is left alone.
    .EXAMPLE
    Update-GpuVMTemplate -Name agent-tpl
    .EXAMPLE
    Update-GpuVMTemplate -Stale
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidatePattern('^[\w-]{1,40}$')][string]$Name,
        # Every agent template that is stale.
        [switch]$Stale,
        # Even when it is current.
        [switch]$Force
    )
    Assert-Admin
    if (-not $Name -and -not $Stale) { throw 'Name a template, or use -Stale for every agent template that needs it.' }
    $names = if ($Name) { @($Name) } else {
        $root = Get-TemplateRoot
        @(if (Test-Path -LiteralPath $root) { Get-ChildItem -LiteralPath $root -Directory | Where-Object Name -match '^[\w-]{1,40}$' | ForEach-Object Name })
    }
    $bundled = Get-BundledComponentStamp
    foreach ($n in $names) {
        $meta = try { Read-GpuVMTemplate -Name $n } catch { if ($Name) { throw }; Write-Warning $_.Exception.Message; continue }
        if ([string]$meta['use'] -ne 'agent') {
            if ($Name) { throw "'$n' isn't an agent template; only those are updated." }
            continue
        }
        if (-not $Force -and -not (Test-GpuVMTemplateStale -Template $meta -Bundled $bundled)) {
            if ($Name) { Write-Step "The template '$n' already has this GpuVM's agent and Sunshine." }
            continue
        }
        if (Test-TemplateUpdating -Template $meta) { Write-Warning "The template '$n' is already being updated."; continue }
        if (-not $PSCmdlet.ShouldProcess($n, 'Add a layer with this GpuVM''s agent and Sunshine')) { continue }
        Add-TemplateLayer -Template $meta -Bundled $bundled
    }
}

# The update itself (see Update-GpuVMTemplate). Returns {name, layer, layers, ms}.
function Add-TemplateLayer {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Template, [System.Collections.IDictionary]$Bundled)
    $ErrorActionPreference = 'Stop'
    $n = $Template['name']
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $copy = ("$n" + '-update') -replace '^(.{40}).*$', '$1'
    $marker = Get-TemplateUpdateMarker -Template $Template
    $index = $Template['layerPaths'].Count
    $layerName = "$n.$index.vhdx"
    $layer = Join-Path $Template['dir'] $layerName
    # Hyper-V only opens a disk whose name ends in .vhdx.
    $building = Join-Path $Template['dir'] "$n.$index.building.vhdx"
    if (Test-Path -LiteralPath $layer) { throw "The template '$n' already has a disk called $layerName that it doesn't use." }
    Write-JsonFile -Path $marker -Data ([ordered]@{ pid = $PID; startedAt = (Get-Date).ToUniversalTime().ToString('o'); copy = $copy })
    try {
        # Left over from an update that died (only the update's own copy, by its name and template).
        if (Get-VM -Name $copy -ErrorAction SilentlyContinue) {
            $old = try { Get-GpuVMState -Name $copy } catch { $null }
            if (-not $old -or [string]$old['template'] -ne $n) { throw "A machine called '$copy' exists and isn't an update of '$n'; rename it first." }
            Remove-GpuVM -Name $copy -DeleteDisk -Confirm:$false
        }
        if (Test-Path -LiteralPath $building) { Remove-Item -LiteralPath $building -Force }
        Write-Step "Updating the template '$n' with this GpuVM's agent and Sunshine (a temporary copy, a few minutes)"
        $null = New-GpuVMFromTemplate -Name $copy -Template $n
        Start-VM -Name $copy
        $signIn = if ([string]$Template['agentSignInAs'] -eq 'own') { 'own' } else { 'agent' }
        $installed = Install-GpuVMAgent -Name $copy -User $signIn
        $credential = Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $copy)
        # Right after the install Windows shuts down but the machine never turns off (lab 053 part 6: the guest logs
        # its shutdown 3 s in, Hyper-V waits 90 s and turns it off). After one more boot it shuts down in seconds, and
        # only a clean shutdown makes a layer worth copying.
        if (-not $installed['restarted']) { Restart-GpuVMCold -Name $copy }
        Wait-GuestReady -Name $copy -Credential $credential | Out-Null
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
        # The template folder's permissions (Administrators and SYSTEM), not the copy's (it carried the VM's own access).
        & icacls.exe $building /reset /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Couldn't set the permissions of $building." }
        $keys = @($Bundled.Keys)
        $components = Invoke-WithMountedWindows -Path $building -ScriptBlock {
            param($root)
            # Never the copy's secret or Sunshine identity: every copy of the template gets its own.
            Reset-ClonedGuestIdentity -WindowsRoot $root
            Get-GuestComponentStamp -WindowsRoot $root -Keys $keys
        }
        foreach ($key in $keys) {
            if ([string]$components[$key] -ne [string]$Bundled[$key]) { throw "The temporary copy doesn't have this GpuVM's $(Split-Path $key -Leaf); the template stays as it was." }
        }
        Move-Item -LiteralPath $building -Destination $layer
        (Get-Item -LiteralPath $layer).IsReadOnly = $true

        $metaPath = Join-Path $Template['dir'] 'template.json'
        $data = Read-JsonFile $metaPath
        $data['layers'] = @($Template['layerPaths'] | ForEach-Object { Split-Path $_ -Leaf }) + $layerName
        $data['components'] = $components
        $data['updatedAt'] = (Get-Date).ToString('o')
        Write-JsonFile -Path $metaPath -Data $data
        $timing['total'] = $sw.ElapsedMilliseconds
        Write-Step "Template '$n' is up to date (layer $index, $([math]::Round((Get-Item -LiteralPath $layer).Length / 1MB)) MB)"
        [ordered]@{ name = $n; layer = $layerName; layers = $index + 1; ms = $timing }
    }
    catch {
        if (Test-Path -LiteralPath $layer) {
            # Written but not recorded: not part of the template.
            (Get-Item -LiteralPath $layer).IsReadOnly = $false
            Remove-Item -LiteralPath $layer -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    finally {
        if (Get-VM -Name $copy -ErrorAction SilentlyContinue) {
            try { Remove-GpuVM -Name $copy -DeleteDisk -Confirm:$false } catch { Write-Warning "The temporary copy '$copy' couldn't be deleted: $($_.Exception.Message)" }
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
