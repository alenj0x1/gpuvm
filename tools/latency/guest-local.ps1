# The input-latency reference inside a VM: the target and the meter both run in the VM's desktop session, without
# streaming, so the VM's own cost (input to its composed screen) is told apart from what the stream adds.
# Run as administrator on the host; the meter runs in the VM through a one-shot task of the signed-in user.
#   tools/latency/guest-local.ps1 -Name win-gpu
# Takes over the VM's screen for about a minute; no stream may be open (the target covers the VM's desktop).
param(
    [Parameter(Mandatory)][string]$Name,
    [int]$Samples = 40,
    [string]$Out = (Join-Path $PSScriptRoot "..\..\labs\020-input-latency\out\guest-local-$(Get-Date -Format 'yyyyMMdd-HHmmss').json")
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$vm = Get-LatencyVM -Name $Name
$session = New-PSSession -VMName $Name -Credential $vm.Guest
try {
    Invoke-Command -Session $session { New-Item -ItemType Directory -Force C:\GpuVM\latency | Out-Null; Remove-Item C:\GpuVM\latency\result.json -ErrorAction SilentlyContinue }
    foreach ($f in 'input-target.ps1', 'input-meter.ps1') { Copy-Item (Join-Path $PSScriptRoot $f) -Destination C:\GpuVM\latency\ -ToSession $session -Force }
    $result = Invoke-Command -Session $session -ArgumentList $Samples -ScriptBlock {
        param($samples)
        $run = @"
`$ErrorActionPreference = 'Stop'
try {
    `$target = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\GpuVM\latency\input-target.ps1','-Minutes','3'
    Start-Sleep -Seconds 5
    . C:\GpuVM\latency\input-meter.ps1
    `$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    [void][GpuVMInputMeter]::SetCursorPos(`$screen.Left + `$screen.Width / 10, `$screen.Top + `$screen.Height / 6)
    `$null = Measure-InputLatency -Bounds `$screen -Kinds click, key, move -Samples 3
    `$rows = Measure-InputLatency -Bounds `$screen -Kinds key, click, move -Samples $samples
    Stop-Process -Id `$target.Id -Force -ErrorAction SilentlyContinue
    @{ screen = "`$(`$screen.Width)x`$(`$screen.Height)"; results = @(`$rows) } | ConvertTo-Json -Depth 5 | Set-Content C:\GpuVM\latency\result.json
} catch { @{ error = "`$_" } | ConvertTo-Json | Set-Content C:\GpuVM\latency\result.json }
"@
        Set-Content C:\GpuVM\latency\run.ps1 $run
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\GpuVM\latency\run.ps1'
        Register-ScheduledTask -TaskName GpuVM-LatencyLocal -Action $action -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
        try {
            Start-ScheduledTask GpuVM-LatencyLocal
            $deadline = (Get-Date).AddMinutes(4)
            while (-not (Test-Path C:\GpuVM\latency\result.json) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
        } finally { Unregister-ScheduledTask GpuVM-LatencyLocal -Confirm:$false -ErrorAction SilentlyContinue }
        if (Test-Path C:\GpuVM\latency\result.json) { Get-Content C:\GpuVM\latency\result.json -Raw } else { '{"error":"no result in 4 minutes"}' }
    }
    Set-Content -Path $Out -Value $result -Encoding utf8
    $data = $result | ConvertFrom-Json
    if ($data.PSObject.Properties['error']) { "error: $($data.error)" }
    else { foreach ($r in $data.results) { "guest-local $($r.kind): median $($r.medianMs) p95 $($r.p95Ms) misses $($r.misses)" } }
    "saved $Out"
}
finally {
    Invoke-Command -Session $session { Remove-Item C:\GpuVM\latency -Recurse -Force -ErrorAction SilentlyContinue } -ErrorAction SilentlyContinue
    Remove-PSSession $session
}
