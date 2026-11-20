# Lab 055, inside the guest, stage 1: runs as SYSTEM in the console session (started by stage0.ps1). Gives
# gpuvm-stream this session's desktop, sets it a fresh random password nobody stores, and starts Sunshine as that user
# in this session (high integrity when C:\GpuVMLab055\high exists).
$dir = 'C:\GpuVMLab055'
$log = Join-Path $dir 'launch.log'
function Log($what) { Add-Content $log "$(Get-Date -Format HH:mm:ss.fff) stage1: $what" }
try {
    # Lab switch: ddx = the DDX probe as SYSTEM in this session (what Sunshine's service does), then stop.
    if (Test-Path (Join-Path $dir 'ddx')) {
        $arg = Get-Content (Join-Path $dir 'ddx') -Raw
        & (Join-Path $dir 'ddxprobe.exe') 20 (Join-Path $dir 'out\ddx.log') $arg.Trim()
        Log 'ddx probe done'
        return
    }
    Add-Type -Path (Join-Path $dir 'StreamLauncher.cs')
    $sid = (New-Object Security.Principal.NTAccount 'gpuvm-stream').Translate([Security.Principal.SecurityIdentifier]).Value
    Log ([StreamLauncher]::GrantDesktop($sid))
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#%+=?'
    $bytes = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $password = 'Aa1!' + (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] }))
    Set-LocalUser -Name 'gpuvm-stream' -Password (ConvertTo-SecureString $password -AsPlainText -Force)
    $high = Test-Path (Join-Path $dir 'high')
    $exe = 'C:\Program Files\Sunshine\sunshine.exe'
    $conf = 'C:\Program Files\Sunshine\config\sunshine.conf'
    # Lab switches (files in $dir): probe = the WGC probe instead of Sunshine; asagent = the session user's own token;
    # nosid = without the session's logon SID.
    $cmdline = if (Test-Path (Join-Path $dir 'probe')) { "`"$dir\out\probe055.exe`"" } else { "`"$exe`" `"$conf`"" }
    $id = if (Test-Path (Join-Path $dir 'asagent')) { [StreamLauncher]::RunAsSessionUser($cmdline, 'C:\Program Files\Sunshine') }
          else { [StreamLauncher]::RunAsUser('gpuvm-stream', $password, $cmdline, 'C:\Program Files\Sunshine', $high, -not (Test-Path (Join-Path $dir 'nosid')), $sid, (Test-Path (Join-Path $dir 'interactive'))) }
    $password = $null
    Log "sunshine pid $id (high integrity: $high)"
    # Lab: notes how long it lives and how it ends (stage 1 is out of the task's job too).
    $t = [Diagnostics.Stopwatch]::StartNew()
    $code = [StreamLauncher]::WaitLast(180000)
    Log ("sunshine: {0} after {1:N1} s" -f $code, $t.Elapsed.TotalSeconds)
}
catch { Log "ERROR $($_.Exception.Message)" }
