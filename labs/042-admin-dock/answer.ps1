# Lab 042, part 2: administrator prompts end to end with GpuVM's own code, before (baseline: the watcher of 0.9.0,
# answer through PowerShell Direct + a one-time SYSTEM task) and after (candidate: watcher that publishes at once with a
# one-time code and keeps a helper waiting on the secure desktop, answer through the host -> guest data exchange).
# Per prompt: when consent.exe appeared in the guest (guest clock mapped to the host's), when the host first lists it
# (the dock can drop), when its program and publisher are known (the buttons can be used), how long the answer takes
# and whether it did what was asked (Allow: the elevated program ran; Deny: it didn't; the prompt closed).
# Also, once per variant: an answer for an old prompt id is refused (forging an answer from the guest: forge.ps1). Variants interleave in rounds (A B, A B). Leaves the candidate watcher
# installed and removes its test folder. Run elevated, with the lab lock held:
#   pwsh -File labs/042-admin-dock/answer.ps1 -Name win-gpu [-Rounds 2] [-PerRound 10]
param(
    [string]$Name = 'win-gpu',
    [int]$Rounds = 2,
    [int]$PerRound = 10,
    [string]$OutDir = (Join-Path $PSScriptRoot "out\answer-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$m = Import-Module (Join-Path $repo 'src\GpuVM\GpuVM.psd1') -Force -PassThru -DisableNameChecking
if ((Get-VM -Name $Name).State -ne 'Running') { throw "La VM '$Name' está apagada." }
$guest = & $m { param($n) Get-GpuVMGuestCredential -State (Get-GpuVMState -Name $n) } $Name
if (-not $guest) { throw "Falta la contraseña de Windows de '$Name' en GpuVM." }
$session = New-PSSession -VMName $Name -Credential $guest
$lab = 'C:\Program Files\GpuVM-lab'
$watchers = @{
    baseline  = ((git -C $repo show 'e29f4ad:guest/admin-prompt.ps1') -join "`n").TrimStart([char]0xFEFF)
    candidate = Get-Content -Raw (Join-Path $repo 'guest\admin-prompt.ps1')
}
$samples = [System.Collections.Generic.List[object]]::new()

function Install-Watcher([string]$Variant) {
    # Same steps as Install-GuestAdminPrompt, with the variant's code.
    Invoke-Command -Session $session -ArgumentList $watchers[$Variant] -ScriptBlock {
        param($code)
        $dir = 'C:\Program Files\GpuVM\AdminPrompt'
        Stop-ScheduledTask -TaskName 'GpuVM-AdminPrompt' -ErrorAction SilentlyContinue
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object CommandLine -like '*admin-prompt.ps1*' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        [IO.File]::WriteAllText((Join-Path $dir 'admin-prompt.ps1'), $code, [Text.UTF8Encoding]::new($true))
        Start-ScheduledTask -TaskName 'GpuVM-AdminPrompt'
    }
    Start-Sleep -Seconds 3
}

function Get-Offset {
    $best = $null
    for ($i = 0; $i -lt 8; $i++) {
        $t0 = [DateTime]::UtcNow.Ticks
        $g = Invoke-Command -Session $session -ScriptBlock { [DateTime]::UtcNow.Ticks }
        $t1 = [DateTime]::UtcNow.Ticks
        if (-not $best -or ($t1 - $t0) -lt $best.rtt) { $best = @{ rtt = $t1 - $t0; offset = $g - ($t0 + $t1) / 2 } }
    }
    $best.offset
}

# Raises a prompt as the signed-in user (cmd.exe asking to write in the admin-only lab folder) and returns the guest
# time consent.exe appeared.
function Open-Prompt {
    Invoke-Command -Session $session -ArgumentList $lab -ScriptBlock {
        param($lab)
        New-Item -ItemType Directory -Force $lab | Out-Null
        Remove-Item (Join-Path $lab 'yes.txt') -ErrorAction SilentlyContinue
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        $script = 'C:\Users\Public\gpuvm-lab042-prompt.ps1'
        Set-Content $script "Start-Process cmd.exe -ArgumentList '/c echo ok > `"$lab\yes.txt`"' -Verb RunAs" -Encoding UTF8
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $script"
        Register-ScheduledTask -TaskName GpuVM-Lab042Prompt -Action $a -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
        Start-ScheduledTask GpuVM-Lab042Prompt
        $seen = $null
        for ($i = 0; $i -lt 1000 -and -not $seen; $i++) {
            if (Get-Process consent -ErrorAction SilentlyContinue) { $seen = [DateTime]::UtcNow.Ticks } else { Start-Sleep -Milliseconds 5 }
        }
        Unregister-ScheduledTask GpuVM-Lab042Prompt -Confirm:$false
        $seen
    }
}

function Get-Outcome {
    for ($i = 0; $i -lt 40; $i++) {
        $o = Invoke-Command -Session $session -ArgumentList $lab -ScriptBlock { param($lab) [pscustomobject]@{ open = [bool](Get-Process consent -ErrorAction SilentlyContinue); ran = Test-Path (Join-Path $lab 'yes.txt') } }
        if (-not $o.open) { Start-Sleep -Milliseconds 500; return Invoke-Command -Session $session -ArgumentList $lab -ScriptBlock { param($lab) [pscustomobject]@{ open = [bool](Get-Process consent -ErrorAction SilentlyContinue); ran = Test-Path (Join-Path $lab 'yes.txt') } } }
        Start-Sleep -Milliseconds 250
    }
    $o
}

function Close-Stray {
    # Answered (Deny), never killed: killing consent.exe can leave the console on the secure desktop.
    $open = & $m { param($n) Get-GuestAdminPromptState -Name $n } $Name
    if ($open) { try { Resolve-GpuVMAdminPrompt -Name $Name -Answer Deny -PromptId $open.id | Out-Null } catch { } }
}

try {
    $checks = [ordered]@{}
    for ($round = 1; $round -le $Rounds; $round++) {
        foreach ($variant in 'baseline', 'candidate') {
            Install-Watcher $variant
            $offset = Get-Offset
            for ($k = 1; $k -le $PerRound; $k++) {
                Close-Stray
                $answer = if ($k % 2) { 'Allow' } else { 'Deny' }
                $openedGuest = Open-Prompt
                if (-not $openedGuest) { Write-Host "$variant #$k no prompt opened"; continue }
                $opened = $openedGuest - $offset
                $listed = $null; $named = $null; $p = $null
                $watch = [Diagnostics.Stopwatch]::StartNew()
                while ($watch.ElapsedMilliseconds -lt 15000 -and -not $named) {
                    $p = & $m { param($n) Get-GuestAdminPromptState -Name $n } $Name
                    $now = [DateTime]::UtcNow.Ticks
                    if ($p -and -not $listed) { $listed = $now }
                    if ($p -and -not $p.reading -and -not $named) { $named = $now }
                    if (-not $named) { Start-Sleep -Milliseconds 20 }
                }
                $sample = [ordered]@{ variant = $variant; round = $round; k = $k; answer = $answer; app = $p.app; publisher = $p.publisher
                    listedMs = if ($listed) { [math]::Round(($listed - $opened) / 1e4) } else { $null }
                    namedMs = if ($named) { [math]::Round(($named - $opened) / 1e4) } else { $null } }
                if ($named) {
                    if ($round -eq 1 -and $k -eq 1) {
                        try { Resolve-GpuVMAdminPrompt -Name $Name -Answer Allow -PromptId ($p.id + 1) | Out-Null; $checks["$variant-old-id"] = 'ANSWERED (wrong)' }
                        catch { $checks["$variant-old-id"] = "refused: $($_.Exception.Message)" }
                    }
                    $t = [Diagnostics.Stopwatch]::StartNew()
                    try { Resolve-GpuVMAdminPrompt -Name $Name -Answer $answer -PromptId $p.id | Out-Null; $sample.error = $null }
                    catch { $sample.error = $_.Exception.Message }
                    $sample.answerMs = $t.ElapsedMilliseconds
                    $o = Get-Outcome
                    $sample.closed = -not $o.open
                    $sample.ran = $o.ran
                    $sample.correct = $sample.closed -and ($o.ran -eq ($answer -eq 'Allow'))
                }
                $samples.Add([pscustomobject]$sample)
                Write-Host ("{0} r{1} #{2} {3}: listed {4} ms, named {5} ms, answer {6} ms, correct {7} {8}" -f $variant, $round, $k, $answer, $sample.listedMs, $sample.namedMs, $sample.answerMs, $sample.correct, $sample.error)
                Start-Sleep -Milliseconds (Get-Random -Minimum 1500 -Maximum 3000)
            }
        }
    }
    $checks | Format-List | Out-String | Write-Host
    $checks | ConvertTo-Json | Set-Content (Join-Path $OutDir 'checks.json')
}
finally {
    $samples | ConvertTo-Json | Set-Content (Join-Path $OutDir 'samples.json')
    try { Close-Stray } catch { }
    try { Install-Watcher candidate } catch { }
    Invoke-Command -Session $session -ArgumentList $lab -ScriptBlock {
        param($lab)
        Remove-Item -Recurse -Force $lab, 'C:\Users\Public\gpuvm-lab042-prompt.ps1' -ErrorAction SilentlyContinue
        Unregister-ScheduledTask GpuVM-Lab042Prompt -Confirm:$false -ErrorAction SilentlyContinue
    } -ErrorAction SilentlyContinue
    Remove-PSSession $session -ErrorAction SilentlyContinue
}
function Summary($values) {
    $v = @($values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if (-not $v.Count) { return 'n/a' }
    "n={0} mean={1:N0} median={2:N0} p95={3:N0} max={4:N0} ms" -f $v.Count, ($v | Measure-Object -Average).Average, $v[[int][math]::Floor(($v.Count - 1) / 2)], $v[[int][math]::Ceiling(0.95 * $v.Count) - 1], $v[-1]
}
foreach ($variant in 'baseline', 'candidate') {
    $s = @($samples | Where-Object variant -eq $variant)
    "== $variant"
    "  listed (dock can drop):   $(Summary $s.listedMs)"
    "  named (buttons usable):   $(Summary $s.namedMs)"
    "  answer:                   $(Summary $s.answerMs)"
    "  correct: $(@($s | Where-Object correct).Count) / $($s.Count)"
}
