# The agent broker lives in the GpuVM service (app/host/src/agent.rs). The module talks to it over an
# administrators-only pipe with the same lines as the service pipe: {"id","cmd","args"} -> {"type":"result",...}.
# The app and the MCP server send the same commands to the service pipe, where the service answers them itself.

$script:AgentPipeName = 'gpuvm-agent'
$script:AgentPipe = $null
$script:AgentPipeIO = $null
# Mixed into the DPAPI encryption of each VM's secret; the service uses the same (agent.rs SECRET_ENTROPY).
$script:AgentSecretEntropy = [Text.Encoding]::ASCII.GetBytes('GpuVM agent secret v1')
# Inside the guest (protocol.md).
$script:GuestAgentDir = 'C:\ProgramData\GpuVM\Agent'

function Get-GpuVMAgentRoot {
    Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'GpuVM\agents'
}

# One persistent connection per PowerShell session (requests are answered in order).
function Invoke-AgentBroker {
    param(
        [Parameter(Mandatory)][string]$Command,
        [System.Collections.IDictionary]$Arguments = @{}
    )
    if (-not $script:AgentPipe -or -not $script:AgentPipe.IsConnected) {
        $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $script:AgentPipeName, [IO.Pipes.PipeDirection]::InOut)
        try { $pipe.Connect(3000) }
        catch {
            $pipe.Dispose()
            throw 'The GpuVM service isn''t running (or this PowerShell isn''t elevated): start GpuVM and try again.'
        }
        $script:AgentPipe = $pipe
        $script:AgentPipeIO = @{
            Reader = [IO.StreamReader]::new($pipe, [Text.UTF8Encoding]::new($false), $false, 65536, $true)
            Writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 65536, $true)
        }
    }
    $request = [ordered]@{ id = [guid]::NewGuid().ToString('n'); cmd = $Command; args = $Arguments }
    $line = $request | ConvertTo-Json -Depth 20 -Compress
    # Write the newline explicitly: WriteLine would end with CR+LF.
    $script:AgentPipeIO.Writer.Write($line + "`n")
    $script:AgentPipeIO.Writer.Flush()
    $reply = $script:AgentPipeIO.Reader.ReadLine()
    if ($null -eq $reply) {
        $script:AgentPipe.Dispose(); $script:AgentPipe = $null
        throw 'The GpuVM service closed the connection.'
    }
    $result = $reply | ConvertFrom-Json -AsHashtable
    if (-not $result['ok']) {
        $exception = [InvalidOperationException]::new([string]$result['error'])
        $exception.Data['code'] = $result['code']
        throw $exception
    }
    # Items one by one (the caller wraps with @() when it wants a list).
    foreach ($item in $result['data']) { $item }
}

# A function's bound parameters as broker arguments: common parameters (-Verbose...) left out, switches as booleans.
function ConvertTo-AgentArguments {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Bound)
    $common = [System.Management.Automation.Cmdlet]::CommonParameters + [System.Management.Automation.Cmdlet]::OptionalCommonParameters
    $result = @{}
    foreach ($key in $Bound.Keys) {
        if ($key -in $common) { continue }
        $value = $Bound[$key]
        $result[$key] = if ($value -is [switch]) { $value.IsPresent } else { $value }
    }
    $result
}

# ProgramData\GpuVM\agents\<vmid>: SYSTEM and Administrators only, nothing inherited (the service trusts what is in it).
function Initialize-AgentFolder {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Path is a link; GpuVM won't use it." }
    & icacls.exe $Path /setowner '*S-1-5-32-544' /Q | Out-Null
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Couldn't restrict the permissions of $Path." }
}

# Writes the VM's secret K for the service: DPAPI machine scope + GpuVM's entropy, in a file only SYSTEM can read.
function Write-AgentSecret {
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][byte[]]$Secret)
    $protected = [Security.Cryptography.ProtectedData]::Protect($Secret, $script:AgentSecretEntropy,
        [Security.Cryptography.DataProtectionScope]::LocalMachine)
    $temp = Join-Path $Folder 'secret.new'
    [IO.File]::WriteAllBytes($temp, $protected)
    & icacls.exe $temp /inheritance:r /grant:r '*S-1-5-18:F' /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { Remove-Item -LiteralPath $temp -Force; throw 'Couldn''t protect the agent''s secret.' }
    Move-Item -LiteralPath $temp -Destination (Join-Path $Folder 'secret') -Force
}


# The guest agent: guest\agent\install.ps1 and gpuvm-agent.exe (dist\ in an installed GpuVM, target\release\ in a
# developer's copy). The version is what the exe itself says (`gpuvm-agent.exe version`).
function Get-AgentPackage {
    $root = Get-RepoPath 'guest\agent'
    $install = Join-Path $root 'install.ps1'
    $exe = @((Join-Path $root 'dist\gpuvm-agent.exe'), (Join-Path $root 'target\release\gpuvm-agent.exe')) |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not (Test-Path -LiteralPath $install) -or -not $exe) { throw "The guest agent isn't in this GpuVM build ($root)." }
    $version = try { (& $exe version 2>$null | Out-String).Trim() } catch { $null }
    [pscustomobject]@{ Install = $install; Exe = $exe; Version = $version; Hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash }
}

# Deletes the agent's secret from a mounted guest disk (a template or a copy of one): copies never share a secret.
function Remove-GuestAgentSecret {
    param([Parameter(Mandatory)][string]$WindowsRoot)
    $path = Join-Path $WindowsRoot 'ProgramData\GpuVM\Agent\secret'
    Assert-NoReparsePoint -Root $WindowsRoot -Path $path
    if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) }
}

# Called when a VM is deleted or renamed: the service finds agents by these registrations.
function Remove-GpuVMAgentRegistration {
    param([Parameter(Mandatory)][string]$VMId)
    $dir = Join-Path (Get-GpuVMAgentRoot) $VMId.ToLowerInvariant()
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
}

function Update-GpuVMAgentRegistration {
    param([Parameter(Mandatory)][string]$Name)
    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) { return }
    $file = Join-Path (Join-Path (Get-GpuVMAgentRoot) $vm.Id.Guid.ToLowerInvariant()) 'agent.json'
    if (-not (Test-Path -LiteralPath $file)) { return }
    $registration = Read-JsonFile $file
    $state = Get-GpuVMState -Name $Name
    $registration['name'] = $Name
    $registration['folder'] = Split-Path $state['statePath'] -Parent
    Write-JsonFile -Path $file -Data $registration
}

# Ends a PowerShell Direct session (a function so tests can replace it).
function Close-AgentSession {
    param($Session)
    Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
}

# PowerShell Direct calls in one session (functions so tests can replace them; a PSSession can't be faked).
function Invoke-InAgentSession {
    param($Session, [scriptblock]$ScriptBlock, [object[]]$ArgumentList = @())
    Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
}

function Copy-ToAgentSession {
    param($Session, [string]$Path, [string]$Destination)
    Copy-Item -LiteralPath $Path -ToSession $Session -Destination $Destination -ErrorAction Stop
}
