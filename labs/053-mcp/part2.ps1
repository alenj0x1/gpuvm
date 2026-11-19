# Lab 053 part 2: the MCP server of the INSTALLED GpuVM against real machines, under the shared lab lock.
#   pwsh -NoProfile -File labs/053-mcp/part2.ps1 -Template <template> [-SkipModel]
# 1. Takes C:\GpuVM\.lab-lock (labs/042-admin-dock/take-lock.ps1, queue-aware) as 'agent-mcp'.
# 2. Preflight: installed gpuvm.exe, GpuVM service running, the template listed, enough free memory.
# 3. drive.py (MCP client, modern era): disposable from the template, latency, coordinate round trip against the
#    VM's real cursor, misuse, destroy-then-use; then the legacy era's latency on a second disposable.
# 4. Claude Code with a real model (unless -SkipModel): disposable, Notepad, command, Outbox offer, destroy.
# 5. Releases the lock in finally. Every disposable it creates is destroyed by drive.py's cleanup / the prompt.
param(
    [Parameter(Mandatory)][ValidatePattern('^[\w-]{1,40}$')][string]$Template,
    [string]$Exe = 'C:\Program Files\GpuVM\gpuvm.exe',
    [int]$Rounds = 40,
    [int]$Samples = 12,
    [int]$MemoryGB = 4,
    # The installer the demo tests inside the disposable machine.
    [string]$Installer = 'C:\Users\you\Desktop\gpu-vm\app\src-tauri\target\release\bundle\nsis\GpuVM_0.9.0_x64-setup.exe',
    [int]$HumanWaitSeconds = 180,
    [switch]$SkipModel,
    # The caller already took the lock as 'agent-mcp' (it is still released at the end).
    [switch]$HaveLock,
    # Only the real-model demo (the measurements were taken already).
    [switch]$ModelOnly
)
$ErrorActionPreference = 'Stop'
$me = 'agent-mcp'
$lockFile = 'C:\GpuVM\.lab-lock'
$outDir = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $outDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $outDir "part2-$stamp.log"
function Log([string]$Text) { $line = "$(Get-Date -Format 'HH:mm:ss') $Text"; $line; Add-Content -LiteralPath $log $line }

if ($HaveLock) {
    if (-not ((Test-Path $lockFile) -and ((Get-Content $lockFile -Raw) -like "$me |*"))) { throw "-HaveLock, but $lockFile isn't held by $me." }
}
else {
    & (Join-Path $PSScriptRoot '..\042-admin-dock\take-lock.ps1') -What "lab 053 MCP part 2 ($Template)" -Me $me -MaxMinutes 180
    if ($LASTEXITCODE -ne 0) { throw 'No lab lock.' }
}
$vmsBefore = @(Get-VM | ForEach-Object Name)
try {
    # Preflight: fail fast with a clear reason.
    if (-not $SkipModel -and -not (Test-Path -LiteralPath $Installer)) { throw "No installer at $Installer." }
    if (-not (Test-Path -LiteralPath $Exe)) { throw "GpuVM isn't installed at $Exe." }
    $svc = Get-Service GpuVM -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') { throw 'The GpuVM service is not running.' }
    $freeGB = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)
    Log "free memory $freeGB GB"
    if ($freeGB -lt $MemoryGB + 0.8) { throw "Only $freeGB GB of memory free: a disposable machine of $MemoryGB GB needs more." }
    $version = (Get-Item -LiteralPath $Exe).VersionInfo.FileVersion
    Log "gpuvm.exe $version"

    $drive = Join-Path $PSScriptRoot 'drive.py'
    if (-not $ModelOnly) {
    Log 'modern era: create, latency, coords, misuse, finale'
    python $drive --exe $Exe --era modern --template $Template --memory $MemoryGB --phases latency,coords,misuse,finale --rounds $Rounds --samples $Samples 2>&1 | Tee-Object -FilePath (Join-Path $outDir "part2-$stamp-modern.txt")
    # Fail fast: if the first disposable couldn't be made, the others won't be either.
    if (Select-String -Path (Join-Path $outDir "part2-$stamp-modern.txt") -Pattern '^no machine' -Quiet) { throw 'The first disposable machine could not be created; see the modern run above.' }
    Log 'legacy era: create, latency, finale'
    python $drive --exe $Exe --era legacy --template $Template --memory $MemoryGB --phases latency,finale --rounds ([math]::Max(10, [int]($Rounds / 4))) 2>&1 | Tee-Object -FilePath (Join-Path $outDir "part2-$stamp-legacy.txt")
    }

    if (-not $SkipModel) {
        $config = Join-Path $outDir "mcp-installed.json"
        @{ mcpServers = @{ gpuvm = @{ type = 'stdio'; command = $Exe; args = @('--mcp') } } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $config -Encoding utf8
        # The demo: test GpuVM's own installer in a clean Windows, while the person can watch.
        $prompt = "Test the GpuVM installer in a clean Windows, using only the gpuvm MCP tools. " +
            "1. Create a disposable machine from the $Template template named lab053-demo with memoryGB $MemoryGB and task 'Test the GpuVM installer'. " +
            "2. Open the viewer so I can watch. 3. Send $Installer from this PC into the machine. " +
            "4. Run it from Desktop\Received (double-click it or start it). Installing needs administrator rights: when a UAC prompt or an administrator window blocks you, " +
            "ask me with request_human (say exactly what to accept) and wait up to $HumanWaitSeconds seconds; if I don't hand it back, stop installing, withdraw your request with cancel_request and say so in the report. " +
            "5. If it installed, check it like a user would (Start menu entry, C:\Program Files\GpuVM, open the app once) and take screenshots of what you see. " +
            "6. Write a short Markdown report in Desktop\Outbox\gpuvm-install-report.md (what you did, what you saw, what failed) and offer it to me with a note. " +
            "7. Destroy the machine. Finally report each step in one line."
        Log 'Claude Code with a real model'
        $env:GPUVM_MCP_LOG = '1'
        $jsonl = Join-Path $outDir "part2-$stamp-claude.jsonl"
        $started = Get-Date
        # Empty stdin (claude -p otherwise waits 3 s for piped input).
        '' | claude -p --strict-mcp-config --mcp-config $config --allowedTools 'mcp__gpuvm' --output-format stream-json --verbose $prompt > $jsonl 2> (Join-Path $outDir "part2-$stamp-claude.err")
        Log "claude exit $LASTEXITCODE after $([int]((Get-Date) - $started).TotalSeconds) s -> $jsonl"
    }
}
finally {
    # Machines this run created and didn't destroy (the model may stop early, or leave one paused for the person).
    $left = @(Get-VM | Where-Object { $_.Name -notin $vmsBefore -and $_.Name -match '^(lab053-|agent-tpl-)' })
    foreach ($vm in $left) {
        Log "deleting leftover disposable $($vm.Name)"
        Stop-VM -Name $vm.Name -TurnOff -Force -ErrorAction SilentlyContinue
    }
    if ($left) {
        Import-Module (Join-Path (Split-Path $Exe) 'gpuvm\src\GpuVM\GpuVM.psd1') -Force -DisableNameChecking
        Remove-GpuVMDisposable -Confirm:$false
    }
    # Release only our own lock.
    if ((Test-Path $lockFile) -and ((Get-Content $lockFile -Raw) -like "$me |*")) { Remove-Item -LiteralPath $lockFile -Force }
    Log 'lab lock released'
}
