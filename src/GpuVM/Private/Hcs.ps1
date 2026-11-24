# Machines run by the Host Compute Service (backend 'hcs'), for Windows editions without Hyper-V. The engine lives in
# the service (gpuvm-host.exe hcs ...); the guest is reached through GpuVM's agent (sys.* methods) instead of
# PowerShell Direct, KVP and the Hyper-V heartbeat. The Get-VM* functions below shadow Hyper-V's inside this module:
# Hyper-V machines pass through untouched, HCS machines are added with the properties the module reads.

$script:HyperVAvailable = [bool](Get-Module -ListAvailable -Name Hyper-V)
$script:HcsRecord = 'hcs-machine.json'
$script:HcsStateCache = @{ At = [datetime]::MinValue; Machines = @() }

function Get-GpuVMHostExe {
    $installed = Join-Path (Split-Path $script:RepoRoot -Parent) 'gpuvm-host.exe'
    foreach ($p in @($installed, (Join-Path $script:RepoRoot 'app\host\target\release\gpuvm-host.exe'), (Join-Path $script:RepoRoot 'app\host\target\debug\gpuvm-host.exe'))) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    throw "GpuVM's service program (gpuvm-host.exe) wasn't found next to the module."
}

function Invoke-GpuVMHcs {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $exe = Get-GpuVMHostExe
    $line = & $exe hcs @Arguments 2>$null | Select-Object -Last 1
    if (-not $line) { throw "gpuvm-host hcs $($Arguments[0]) gave no answer." }
    $reply = $line | ConvertFrom-Json -AsHashtable
    if (-not $reply['ok']) { throw [string]$reply['error'] }
    $reply['result']
}

function Get-GpuVMHcsRoot { Get-GpuVMDefaultRoot }

# What machines without Hyper-V can't do yet, said plainly instead of failing inside a Hyper-V command.
function Assert-HyperVMachine {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$What)
    if (Test-GpuVMHcsMachine -Name $Name) { throw "$What isn't available yet for machines that run without Hyper-V." }
}

function Test-GpuVMHcsMachine {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -notmatch '^[\w-]{1,40}$') { return $false }
    Test-Path -LiteralPath (Join-Path (Join-Path (Get-GpuVMHcsRoot) $Name) $script:HcsRecord) -PathType Leaf
}

# Every HCS machine and whether it runs, from one call (cached a second: the app asks often).
function Get-GpuVMHcsMachines {
    param([switch]$Fresh)
    if (-not $Fresh -and ((Get-Date) - $script:HcsStateCache.At).TotalSeconds -lt 1) { return $script:HcsStateCache.Machines }
    $root = Get-GpuVMHcsRoot
    $machines = @()
    if (Test-Path -LiteralPath $root) {
        $any = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName $script:HcsRecord) })
        if ($any) { $machines = @((Invoke-GpuVMHcs @('list', $root))['machines']) }
    }
    $script:HcsStateCache = @{ At = Get-Date; Machines = $machines }
    $machines
}

function Clear-GpuVMHcsCache { $script:HcsStateCache = @{ At = [datetime]::MinValue; Machines = @() } }

# The machine's agent, through the service's administrative pipe (sys.* are refused anywhere else).
function Invoke-GpuVMHcsAgent {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Method,
        [System.Collections.IDictionary]$Params = @{},
        [byte[]]$Blob,
        [int]$TimeoutSec = 60
    )
    $arguments = @{ Name = $Name; Method = $Method; Params = $Params; TimeoutSec = $TimeoutSec }
    if ($Blob) { $arguments['Blob'] = [Convert]::ToBase64String($Blob) }
    $reply = @(Invoke-AgentBroker -Command 'Invoke-GpuVMAgent' -Arguments $arguments)[0]
    if (-not $reply -or -not $reply['ok']) {
        $code = if ($reply) { $reply['error']['code'] } else { 'off' }
        $message = if ($reply) { $reply['error']['message'] } else { "No answer from the agent on '$Name'." }
        $e = [InvalidOperationException]::new([string]$message)
        $e.Data['code'] = $code
        throw $e
    }
    $bytes = if ($reply['blob']) { [Convert]::FromBase64String($reply['blob']) } elseif ($reply['blobPath']) { [IO.File]::ReadAllBytes($reply['blobPath']) } else { $null }
    [pscustomobject]@{ Result = $reply['result']; Blob = $bytes }
}

function Get-GpuVMHcsInfo {
    param([Parameter(Mandatory)][string]$Name)
    try { (Invoke-GpuVMHcsAgent -Name $Name -Method 'sys.info' -TimeoutSec 10).Result } catch { $null }
}

function Wait-GpuVMHcsAgent {
    param([Parameter(Mandatory)][string]$Name, [int]$TimeoutSec = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $info = Get-GpuVMHcsInfo -Name $Name
        if ($info) { return $info }
        if (-not (Get-GpuVMHcsMachines -Fresh | Where-Object { $_['name'] -eq $Name -and $_['running'] })) { throw "The machine '$Name' is off." }
        Start-Sleep -Seconds 2
    }
    throw "GpuVM's agent on '$Name' didn't answer in $TimeoutSec s."
}

# Runs a script block in the guest as SYSTEM, the way PowerShell Direct did: the block and its arguments go in as
# CliXml, the guest's Windows PowerShell runs it, and the result comes back as CliXml (deserialized objects).
function Invoke-HcsGuest {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [ValidateRange(1, 585)][int]$TimeoutSec = 585
    )
    $id = [guid]::NewGuid().ToString('n')
    $dir = 'C:\GpuVM\hcs-run'
    $temp = Join-Path ([IO.Path]::GetTempPath()) "gpuvm-hcs-$id.xml"
    try {
        # As PowerShell Direct sends them: shallow, and strings without the notes Get-Content adds (their PSDrive and
        # provider made one call's CliXml 182 MB).
        $plain = @(foreach ($a in $ArgumentList) { if ($a -is [string]) { [string]::new($a.ToCharArray()) } else { $a } })
        [pscustomobject]@{ Script = $ScriptBlock.ToString(); Args = $plain } | Export-Clixml -LiteralPath $temp -Depth 2
        $null = Invoke-GpuVMHcsAgent -Name $Name -Method 'sys.write' -Params @{ path = "$dir\$id.in.xml" } -Blob ([IO.File]::ReadAllBytes($temp))
        $runner = @'
param([string]$Id)
$dir = 'C:\GpuVM\hcs-run'
$in = Import-Clixml -LiteralPath (Join-Path $dir "$Id.in.xml")
Remove-Item -LiteralPath (Join-Path $dir "$Id.in.xml") -Force -ErrorAction SilentlyContinue
$a = @($in.Args)
$out = try { $sb = [scriptblock]::Create($in.Script); [pscustomobject]@{ Ok = $true; Output = @(& $sb @a) } } catch { [pscustomobject]@{ Ok = $false; Error = "$_" } }
$out | Export-Clixml -LiteralPath (Join-Path $dir "$Id.out.xml") -Depth 6
'@
        $null = Invoke-GpuVMHcsAgent -Name $Name -Method 'sys.write' -Params @{ path = "$dir\runner.ps1" } -Blob ([Text.UTF8Encoding]::new($true).GetBytes($runner))
        $run = (Invoke-GpuVMHcsAgent -Name $Name -Method 'sys.exec' -TimeoutSec ($TimeoutSec + 15) -Params @{
                file = 'WindowsPowerShell\v1.0\powershell.exe'; timeoutMs = $TimeoutSec * 1000
                args = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "$dir\runner.ps1", '-Id', $id) }).Result
        if ($run['timedOut']) { throw "The command in '$Name' didn't finish in $TimeoutSec s." }
        $back = Invoke-GpuVMHcsAgent -Name $Name -Method 'sys.read' -Params @{ path = "$dir\$id.out.xml" }
        [IO.File]::WriteAllBytes($temp, $back.Blob)
        $null = Invoke-GpuVMHcsAgent -Name $Name -Method 'sys.exec' -Params @{ file = 'cmd.exe'; args = @('/c', 'del', '/q', "$dir\$id.out.xml") }
        $out = Import-Clixml -LiteralPath $temp
        if (-not $out.Ok) { throw [string]$out.Error }
        $out.Output
    }
    finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}

function ConvertTo-HcsVMObject {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Machine)
    $root = Get-GpuVMHcsRoot
    $dir = Join-Path $root $Machine['name']
    $running = [bool]$Machine['running']
    $memory = [int64]$Machine['memoryMB'] * 1MB
    $id = if ($Machine['vmId']) { [guid]$Machine['vmId'] } else { [guid]::Empty }
    $folder = Get-Item -LiteralPath $dir -ErrorAction SilentlyContinue
    [pscustomobject]@{
        PSTypeName            = 'GpuVM.HcsMachine'
        Name                  = [string]$Machine['name']
        Id                    = $id
        VMId                  = $id
        State                 = if ($running) { 'Running' } else { 'Off' }
        Path                  = $root
        ConfigurationLocation = $dir
        SnapshotFileLocation  = $dir
        SmartPagingFilePath   = $dir
        MemoryStartup         = $memory
        MemoryAssigned        = if ($running) { $memory } else { 0 }
        MemoryDemand          = if ($running) { $memory } else { 0 }
        ProcessorCount        = [int]$Machine['cpus']
        Uptime                = [timespan]::Zero
        CPUUsage              = 0
        Generation            = 2
        CreationTime          = if ($folder) { $folder.CreationTime } else { $null }
        Backend               = 'hcs'
    }
}

function Test-HcsVMObject { param($VM) $VM -and $VM.PSObject.TypeNames -contains 'GpuVM.HcsMachine' }

function Get-VM {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string[]]$Name, [guid]$Id)
    $found = [Collections.Generic.List[object]]::new()
    if ($script:HyperVAvailable) {
        $splat = @{ ErrorAction = 'SilentlyContinue' }
        if ($Name) { $splat['Name'] = $Name }
        if ($Id -and $Id -ne [guid]::Empty) { $splat['Id'] = $Id }
        $splat['ErrorVariable'] = 'hvErrors'
        foreach ($vm in @(Hyper-V\Get-VM @splat)) { if ($vm) { $found.Add($vm) } }
        # Only "no machine with that name" is left out (an HCS machine may have it); Hyper-V failing is reported,
        # so callers asking with -ErrorAction Stop still stop instead of seeing an empty list.
        foreach ($e in @($hvErrors)) {
            # Recognized by its id, not its (translated) text.
            if ($Name -and $e.FullyQualifiedErrorId -like 'InvalidParameter,Microsoft.HyperV.PowerShell.Commands.GetVM*') { continue }
            $PSCmdlet.WriteError($e)
        }
    }
    foreach ($m in @(Get-GpuVMHcsMachines)) {
        # Wildcards as Hyper-V's Get-VM takes them (Get-GpuVM asks for '*').
        if ($Name -and -not @($Name | Where-Object { $m['name'] -like $_ })) { continue }
        if ($Id -and $Id -ne [guid]::Empty -and $m['vmId'] -ne $Id.Guid) { continue }
        if ($found | Where-Object Name -eq $m['name']) { continue }
        $found.Add((ConvertTo-HcsVMObject $m))
    }
    if ($Name -and $found.Count -eq 0 -and -not @($Name | Where-Object { [WildcardPattern]::ContainsWildcardCharacters($_) })) {
        $err = [Management.Automation.ErrorRecord]::new([Management.Automation.ItemNotFoundException]::new("Hyper-V was unable to find a virtual machine with name `"$($Name -join ', ')`"."), 'InvalidParameter', 'ObjectNotFound', $Name)
        $PSCmdlet.WriteError($err)
        return
    }
    $found
}

function Get-HcsVMByName { param([string]$Name) if (Test-GpuVMHcsMachine -Name $Name) { Get-VM -Name $Name -ErrorAction SilentlyContinue | Where-Object { Test-HcsVMObject $_ } | Select-Object -First 1 } }

function Get-VMHardDiskDrive {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$VM, [string[]]$VMName, [string]$ControllerType, $ControllerNumber, $ControllerLocation)
    process {
        $targets = if ($VM) { @($VM) } else { @($VMName | ForEach-Object { $_ }) }
        foreach ($t in $targets) {
            $name = if ($t -is [string]) { $t } else { $t.Name }
            if (Test-GpuVMHcsMachine -Name $name) {
                if ($ControllerType -and $ControllerType -ne 'SCSI') { continue }
                [pscustomobject]@{ VMName = $name; Path = Join-Path (Join-Path (Get-GpuVMHcsRoot) $name) 'disk.vhdx'; ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 0 }
                continue
            }
            if (-not $script:HyperVAvailable) { continue }
            $splat = @{}
            foreach ($k in 'ControllerType', 'ControllerNumber', 'ControllerLocation') { if ($PSBoundParameters.ContainsKey($k)) { $splat[$k] = $PSBoundParameters[$k] } }
            if ($t -is [string]) { Hyper-V\Get-VMHardDiskDrive -VMName $t @splat } else { Hyper-V\Get-VMHardDiskDrive -VM $t @splat }
        }
    }
}

function Get-VMNetworkAdapter {
    [CmdletBinding()]
    param([string]$VMName, [Parameter(ValueFromPipeline)]$VM, [string]$Name, [switch]$ManagementOS, [string]$SwitchName)
    process {
        $target = if ($VMName) { $VMName } elseif ($VM) { $VM.Name } else { $null }
        if ($target -and (Test-GpuVMHcsMachine -Name $target)) {
            $m = @(Get-GpuVMHcsMachines | Where-Object { $_['name'] -eq $target })[0]
            $info = if ($m -and $m['running']) { Get-GpuVMHcsInfo -Name $target } else { $null }
            $ips = if ($info -and $info.Contains('ipv4')) { @($info['ipv4'] | Where-Object { $_ }) } else { @() }
            # The host's adapter on the machine's network is "vEthernet (<network>)" (net.rs).
            $switch = if ($m -and $m['isolated']) { "GpuVM-$target" } else { 'GpuVM' }
            $mac = if ($m) { ([string]$m['mac']) -replace '-', '' } else { '' }
            return [pscustomobject]@{ VMName = $target; Name = 'Network Adapter'; SwitchName = $switch; IPAddresses = $ips; MacAddress = $mac }
        }
        if ($script:HyperVAvailable) { Hyper-V\Get-VMNetworkAdapter @PSBoundParameters }
    }
}

function Get-VMGpuPartitionAdapter {
    [CmdletBinding()]
    param([string]$VMName, [Parameter(ValueFromPipeline)]$VM)
    process {
        $target = if ($VMName) { $VMName } else { $VM.Name }
        if ($target -and (Test-GpuVMHcsMachine -Name $target)) {
            $m = Get-GpuVMHcsMachines | Where-Object { $_['name'] -eq $target } | Select-Object -First 1
            if ($m -and [string]$m['gpu'] -ne 'none') { return [pscustomobject]@{ VMName = $target; InstancePath = [string]$m['gpu'] } }
            return
        }
        if ($script:HyperVAvailable) { Hyper-V\Get-VMGpuPartitionAdapter @PSBoundParameters }
    }
}

function Get-VMIntegrationService {
    [CmdletBinding()]
    param([string]$VMName, [Parameter(ValueFromPipeline)]$VM, [string]$Name)
    process {
        $target = if ($VMName) { $VMName } else { $VM.Name }
        if ($target -and (Test-GpuVMHcsMachine -Name $target)) {
            $up = [bool](Get-GpuVMHcsInfo -Name $target)
            return [pscustomobject]@{ VMName = $target; Name = 'Heartbeat'; Id = 'Microsoft:00000000-0000-0000-0000-000000000000\84EAAE65-2F2E-45F5-9BB5-0E857DC8EB47'
                Enabled = $true; PrimaryOperationalStatus = if ($up) { 'Ok' } else { 'NoContact' }; PrimaryStatusDescription = if ($up) { 'OK (GpuVM agent)' } else { 'No contact' } }
        }
        if ($script:HyperVAvailable) { Hyper-V\Get-VMIntegrationService @PSBoundParameters }
    }
}

# Power for HCS machines: a start makes the compute system from the machine's record; a stop asks Windows to shut
# down through the agent and pulls the plug only if it doesn't, or when asked to.
# The machine's record follows its GpuVM config: isolated (the default, always for agent machines) puts it on GpuVM's
# isolated network with the host relay at its next start. A running machine changes network only when it restarts.
function Sync-HcsIsolation {
    param([Parameter(Mandatory)][string]$Name, [System.Collections.IDictionary]$State)
    if (-not $State) { $State = try { Get-GpuVMState -Name $Name } catch { $null } }
    $want = if ($State) { [bool](Get-GpuVMNetworkIsolation -State $State) } else { $true }
    $m = @(Get-GpuVMHcsMachines -Fresh | Where-Object { $_['name'] -eq $Name })[0]
    if (-not $m -or [bool]$m['isolated'] -eq $want) { return }
    if ($m['running']) {
        # Taking isolation away waits for the next start; isolating can't wait: the machine must start again first.
        if ($want) { throw "The VM '$Name' is running without network isolation; turn it off and start it again to isolate it." }
        Write-Warning "The VM '$Name' is running: it keeps network isolation until it starts again."
        return
    }
    $null = Invoke-GpuVMHcs @('set', (Get-GpuVMHcsRoot), $Name, '--isolated', $want.ToString().ToLowerInvariant())
    Clear-GpuVMHcsCache
}

function Start-HcsMachine {
    param([Parameter(Mandatory)][string]$Name)
    Sync-HcsIsolation -Name $Name
    $started = Invoke-GpuVMHcs @('start', (Get-GpuVMHcsRoot), $Name)
    Clear-GpuVMHcsCache
    $gpu = [string]$started['gpu']
    if ($gpu -and $gpu -ne 'shared' -and $gpu -notlike 'no GPU*') { Write-Warning "The machine '$Name' started without the GPU: $gpu" }
}

function Stop-HcsMachine {
    param([Parameter(Mandatory)][string]$Name, [switch]$TurnOff, [int]$TimeoutSec = 120)
    $root = Get-GpuVMHcsRoot
    if (-not $TurnOff) {
        $asked = $false
        try { $null = Invoke-GpuVMHcsAgent -Name $Name -Method 'sys.power' -Params @{ action = 'shutdown' } -TimeoutSec 15; $asked = $true } catch { }
        if ($asked) {
            $deadline = (Get-Date).AddSeconds($TimeoutSec)
            while ((Get-Date) -lt $deadline -and (Invoke-GpuVMHcs @('state', $root, $Name))['state'] -ne 'Off') { Start-Sleep -Seconds 2 }
        }
    }
    $null = Invoke-GpuVMHcs @('off', $root, $Name)
    Clear-GpuVMHcsCache
}

function Restart-HcsMachine {
    param([Parameter(Mandatory)][string]$Name, [switch]$Wait)
    # A restart inside Windows keeps the machine's network: when its isolation must change, it starts again instead.
    $state = try { Get-GpuVMState -Name $Name } catch { $null }
    $want = if ($state) { [bool](Get-GpuVMNetworkIsolation -State $state) } else { $true }
    $m = @(Get-GpuVMHcsMachines -Fresh | Where-Object { $_['name'] -eq $Name })[0]
    $again = $m -and [bool]$m['isolated'] -ne $want
    try {
        if ($again) { throw 'network change' }
        $null = Invoke-GpuVMHcsAgent -Name $Name -Method 'sys.power' -Params @{ action = 'restart' } -TimeoutSec 15
    }
    catch {
        Stop-HcsMachine -Name $Name -TurnOff:(-not $again)
        Start-HcsMachine -Name $Name
    }
    if ($Wait) {
        Start-Sleep -Seconds 5
        $null = Wait-GpuVMHcsAgent -Name $Name
    }
}

# PowerShell Direct for HCS machines: a script block sent to a machine by name runs through the agent instead.
# Everything else (sessions to Hyper-V machines, local blocks, jobs) goes to PowerShell's own Invoke-Command.
function Invoke-Command {
    [CmdletBinding(DefaultParameterSetName = 'Local')]
    param(
        [Parameter(ParameterSetName = 'VM')][string[]]$VMName,
        [Parameter(ParameterSetName = 'Session')]$Session,
        [pscredential]$Credential,
        [Parameter(Position = 0)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList,
        [switch]$AsJob,
        [string]$FilePath
    )
    $hcsName = if ($PSCmdlet.ParameterSetName -eq 'Session' -and (Test-HcsSession $Session)) { $Session.VMName }
        elseif ($PSCmdlet.ParameterSetName -eq 'VM' -and $VMName.Count -eq 1 -and (Test-GpuVMHcsMachine -Name $VMName[0])) { $VMName[0] }
    if ($hcsName) {
        if ($AsJob) {
            # The job needs the module's own functions: it loads the module and runs the block there.
            $manifest = Join-Path $script:RepoRoot 'src\GpuVM\GpuVM.psd1'
            return Start-ThreadJob -ArgumentList $manifest, $hcsName, $ScriptBlock.ToString(), @($ArgumentList) -ScriptBlock {
                param($m, $n, $s, $a)
                $mod = Import-Module $m -PassThru -DisableNameChecking
                & $mod { param($n, $s, $a) Invoke-HcsGuest -Name $n -ScriptBlock ([scriptblock]::Create($s)) -ArgumentList $a } $n $s $a
            }
        }
        return Invoke-HcsGuest -Name $hcsName -ScriptBlock $ScriptBlock -ArgumentList @($ArgumentList)
    }
    Microsoft.PowerShell.Core\Invoke-Command @PSBoundParameters
}

# A machine without Hyper-V has no PowerShell Direct: its "session" names the machine, and Invoke-Command and
# Copy-Item reach it through the agent. Each command runs on its own, so nothing is kept between commands.
function New-PSSession {
    [CmdletBinding()]
    param([string[]]$VMName, [pscredential]$Credential, [string]$Name)
    if ($VMName -and (Test-GpuVMHcsMachine -Name $VMName[0])) {
        return [pscustomobject]@{ PSTypeName = 'GpuVM.HcsSession'; VMName = $VMName[0]; ComputerName = $VMName[0]; State = 'Opened'; Availability = 'Available' }
    }
    Microsoft.PowerShell.Core\New-PSSession @PSBoundParameters
}

function Test-HcsSession { param($Session) $Session -and $Session.PSObject.TypeNames -contains 'GpuVM.HcsSession' }

function Remove-PSSession {
    [CmdletBinding()]
    param([Parameter(Position = 0, ValueFromPipeline)]$Session)
    process {
        $real = @($Session | Where-Object { -not (Test-HcsSession $_) })
        if ($real) { Microsoft.PowerShell.Core\Remove-PSSession -Session $real -ErrorAction $ErrorActionPreference }
    }
}

# Files go in pieces of 8 MiB (the agent takes 16 MiB per call), each written at its place.
$script:HcsCopyPiece = 8MB

function Copy-Item {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string[]]$Path,
        [string[]]$LiteralPath,
        [Parameter(Position = 1)][string]$Destination,
        $ToSession,
        $FromSession,
        [switch]$Recurse,
        [switch]$Force,
        [switch]$Container,
        [switch]$PassThru
    )
    if (Test-HcsSession $ToSession) {
        $sources = @(if ($LiteralPath) { Get-Item -LiteralPath $LiteralPath -ErrorAction Stop } else { Get-Item -Path $Path -ErrorAction Stop })
        $name = $ToSession.VMName
        $intoFolder = [bool](Invoke-HcsGuest -Name $name -ArgumentList $Destination -ScriptBlock { param($d) Test-Path -LiteralPath $d -PathType Container })
        foreach ($src in $sources) {
            $base = if ($intoFolder) { Join-Path $Destination $src.Name } else { $Destination }
            $files = if ($src.PSIsContainer) {
                if (-not $Recurse) { continue }
                @(Get-ChildItem -LiteralPath $src.FullName -Recurse -File | ForEach-Object { @{ From = $_.FullName; To = Join-Path $base $_.FullName.Substring($src.FullName.Length).TrimStart('\') } })
            } else { @(@{ From = $src.FullName; To = $base }) }
            foreach ($f in $files) { Send-HcsGuestFile -Name $name -Path $f.From -Destination $f.To }
        }
        return
    }
    if (Test-HcsSession $FromSession) {
        $name = $FromSession.VMName
        $source = if ($LiteralPath) { $LiteralPath[0] } else { $Path[0] }
        $target = if (Test-Path -LiteralPath $Destination -PathType Container) { Join-Path $Destination (Split-Path $source -Leaf) } else { $Destination }
        Receive-HcsGuestFile -Name $name -Path $source -Destination $target
        return
    }
    Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
}

function Send-HcsGuestFile {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Destination)
    $stream = [IO.File]::OpenRead($Path)
    try {
        $buffer = [byte[]]::new([math]::Min($script:HcsCopyPiece, [math]::Max(1, $stream.Length)))
        $offset = [int64]0
        do {
            $n = $stream.Read($buffer, 0, $buffer.Length)
            $piece = if ($n -eq $buffer.Length) { $buffer } else { $buffer[0..($n - 1)] }
            if ($n -eq 0) { $piece = [byte[]]::new(0) }
            $null = Invoke-GpuVMHcsAgent -Name $Name -Method 'sys.write' -Params @{ path = $Destination; offset = $offset } -Blob $piece -TimeoutSec 120
            $offset += $n
        } while ($n -gt 0 -and $offset -lt $stream.Length)
    }
    finally { $stream.Dispose() }
}

function Receive-HcsGuestFile {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Destination)
    $out = [IO.File]::Create($Destination)
    try {
        $offset = [int64]0
        do {
            $r = Invoke-GpuVMHcsAgent -Name $Name -Method 'sys.read' -Params @{ path = $Path; offset = $offset; length = $script:HcsCopyPiece } -TimeoutSec 120
            $bytes = if ($r.Blob) { $r.Blob } else { [byte[]]::new(0) }
            $out.Write($bytes, 0, $bytes.Length)
            $offset += $bytes.Length
            $size = [int64]$r.Result['size']
        } while ($bytes.Length -gt 0 -and $offset -lt $size)
    }
    finally { $out.Dispose() }
}

