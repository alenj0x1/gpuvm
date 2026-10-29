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
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $wasRunning = $vm.State -eq 'Running'
    if ($vm.State -ne 'Off' -and -not ($wasRunning -and $ShutdownIfRunning)) { throw "Apaga la VM '$VMName' antes de crear la plantilla." }
    $source = (Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1).Path
    if (-not $source) { throw "La VM '$VMName' no tiene disco." }
    $dir = Get-TemplateDirectory -Name $Name
    if (Test-Path -LiteralPath $dir) { throw "Ya existe una plantilla llamada '$Name'." }
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
    if ($needGB -gt $freeGB) { throw "No hay espacio para la plantilla: hacen falta unos $needGB GB y quedan $freeGB GB libres." }
    if (-not $PSCmdlet.ShouldProcess($Name, "Crear plantilla desde $VMName")) { return }
    if ($wasRunning) {
        Write-Step 'Apagando'
        Stop-VM -Name $VMName -Force
    }

    Initialize-GpuVMRoot -Path (Get-GpuVMDefaultRoot)
    New-Item -ItemType Directory -Path (Get-TemplateRoot) -Force | Out-Null
    Protect-GpuVMSharedFolder -Path (Get-TemplateRoot)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $target = Join-Path $dir "$Name.vhdx"
    try {
        Write-Step "Copiando el disco de $VMName (puede tardar unos minutos)"
        # Convert-VHD copies into a new dynamic disk; a disk that is itself a copy of a template is merged into one.
        Convert-VHD -Path $source -DestinationPath $target -VHDType Dynamic -ErrorAction Stop
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
            })
    }
    catch {
        if (Test-Path -LiteralPath $target) { (Get-Item -LiteralPath $target).IsReadOnly = $false }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    finally {
        if ($wasRunning) {
            Write-Step 'Encendiendo'
            try { Start-VM -Name $VMName -ErrorAction Stop } catch { Write-Warning "No se pudo volver a encender ${VMName}: $($_.Exception.Message)" }
        }
    }
    Write-Step "Plantilla '$Name' lista ($([math]::Round((Get-Item -LiteralPath $target).Length / 1GB, 1)) GB)"
    Get-GpuVMTemplate | Where-Object { $_['name'] -eq $Name }
}
