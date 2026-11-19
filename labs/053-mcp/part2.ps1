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
    [switch]$SkipModel
)
$ErrorActionPreference = 'Stop'
$me = 'agent-mcp'
$lockFile = 'C:\GpuVM\.lab-lock'
$outDir = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $outDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $outDir "part2-$stamp.log"
function Log([string]$Text) { $line = "$(Get-Date -Format 'HH:mm:ss') $Text"; $line; Add-Content -LiteralPath $log $line }

& (Join-Path $PSScriptRoot '..\042-admin-dock\take-lock.ps1') -What "lab 053 MCP part 2 ($Template)" -Me $me -MaxMinutes 180
if ($LASTEXITCODE -ne 0) { throw 'No lab lock.' }
try {
    # Preflight: fail fast with a clear reason.
    if (-not (Test-Path -LiteralPath $Exe)) { throw "GpuVM isn't installed at $Exe." }
    $svc = Get-Service GpuVM -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') { throw 'The GpuVM service is not running.' }
    $freeGB = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)
    Log "free memory $freeGB GB"
    if ($freeGB -lt 5) { throw "Only $freeGB GB of memory free: a disposable machine needs ~4 GB." }
    $version = (Get-Item -LiteralPath $Exe).VersionInfo.FileVersion
    Log "gpuvm.exe $version"

    $drive = Join-Path $PSScriptRoot 'drive.py'
    Log 'modern era: create, latency, coords, misuse, finale'
    python $drive --exe $Exe --era modern --template $Template --phases latency,coords,misuse,finale --rounds $Rounds --samples $Samples 2>&1 | Tee-Object -FilePath (Join-Path $outDir "part2-$stamp-modern.txt")
    Log 'legacy era: create, latency, finale'
    python $drive --exe $Exe --era legacy --template $Template --phases latency,finale --rounds ([math]::Max(10, [int]($Rounds / 4))) 2>&1 | Tee-Object -FilePath (Join-Path $outDir "part2-$stamp-legacy.txt")

    if (-not $SkipModel) {
        $config = Join-Path $outDir "mcp-installed.json"
        @{ mcpServers = @{ gpuvm = @{ type = 'stdio'; command = $Exe; args = @('--mcp') } } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $config -Encoding utf8
        $prompt = "Using only the gpuvm MCP tools: create a disposable machine from the $Template template named lab053-cc. " +
            "Open Notepad (press win+r, type notepad, press enter), type 'Hello from Claude Code' into it, and take a screenshot to check the text is there. " +
            "Run the command 'whoami' and tell me the output. Write a short report in C:\Users\agent\Desktop\Outbox\lab053-report.md and offer it to me with a note. " +
            "Finally destroy the machine. Report each step in one line, with what you saw on screen."
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
    # Release only our own lock.
    if ((Test-Path $lockFile) -and ((Get-Content $lockFile -Raw) -like "$me |*")) { Remove-Item -LiteralPath $lockFile -Force }
    Log 'lab lock released'
}
