function Remove-GpuVMDisposable {
    <#
    .SYNOPSIS
    Deletes the disposable machines that were used and are off, with their disks, and the folders of disposable
    machines left behind (Hyper-V no longer knows them). Running ones are never touched. The app runs it when a
    disposable machine turns off and when it starts.
    .EXAMPLE
    Remove-GpuVMDisposable
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Assert-Admin
    $root = Get-GpuVMDefaultRoot
    $removed = [System.Collections.Generic.List[string]]::new()
    $known = @{}
    # Disposable machines only reserve a fixed amount of the drive: when it gets down to the host's margin, the running
    # ones are shut down cleanly (in the background), and the next sweep deletes them.
    if ((Get-DriveFreeGB $root) -lt $script:DiskMarginGB) {
        foreach ($vm in @(Get-VM -ErrorAction Stop | Where-Object State -eq 'Running')) {
            if (-not (Test-GpuVMDisposableByName -Name $vm.Name)) { continue }
            if (-not $PSCmdlet.ShouldProcess($vm.Name, 'Shut down the disposable machine (low on space)')) { continue }
            Write-Warning "$(Split-Path $root -Qualifier) is running out of space: the disposable machine '$($vm.Name)' shuts down and is deleted."
            Stop-VM -Name $vm.Name -Force -AsJob | Out-Null
        }
    }
    # If Hyper-V doesn't answer, nothing is swept: an empty list would make every disposable machine's folder look left behind.
    $all = try { @(Get-VM -ErrorAction Stop) } catch { Write-Warning "Hyper-V didn't answer; nothing is deleted now: $($_.Exception.Message)"; return }
    foreach ($vm in $all) {
        $known[$vm.Name] = $true
        $state = try { Get-GpuVMState -Name $vm.Name } catch { $null }
        if (-not $state -or -not (Test-GpuVMDisposableDone -State $state -VMState $vm.State.ToString())) { continue }
        if (-not $PSCmdlet.ShouldProcess($vm.Name, 'Delete the disposable machine')) { continue }
        Write-Step "Deleting the disposable machine '$($vm.Name)'"
        # Only its own folder inside GpuVM's root is deleted (the backend refuses any other path).
        try {
            Invoke-GpuVMBackend -Backend $state['backend'] -Operation Remove -Arguments $vm.Name, $state, $true
            $removed.Add($vm.Name)
        }
        catch { Write-Warning "Couldn't delete the disposable machine '$($vm.Name)': $($_.Exception.Message)" }
    }
    # A disposable machine whose VM is gone (the app or PC closed halfway through deleting it): its folder goes too.
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object Name -notlike '.*')) {
        if ($known.ContainsKey($dir.Name) -or $dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $statePath = Join-Path $dir.FullName 'gpuvm.json'
        if (-not (Test-Path -LiteralPath $statePath)) { continue }
        $state = try { Read-JsonFile $statePath } catch { $null }
        if (-not (Test-GpuVMDisposable -State $state)) { continue }
        if ([string]$state['name'] -ne $dir.Name) { continue }
        if (-not $PSCmdlet.ShouldProcess($dir.Name, 'Delete what was left of the disposable machine')) { continue }
        Write-Step "Deleting what was left of the disposable machine '$($dir.Name)'"
        foreach ($disk in @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -Filter *.vhdx -File -ErrorAction SilentlyContinue)) {
            if ((Get-VHD -Path $disk.FullName -ErrorAction SilentlyContinue).Attached) { Dismount-VHD -Path $disk.FullName -ErrorAction SilentlyContinue }
        }
        try { Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop; $removed.Add($dir.Name) }
        catch { Write-Warning "Couldn't delete $($dir.FullName): $($_.Exception.Message)" }
    }
    # One name per deleted machine (nothing when none): the app reads the list as is.
    $removed.ToArray()
}
