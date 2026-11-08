# Lab 025: can GpuVM tell, cheaply and quickly, that Windows in the VM shows an administrator prompt (which WGC
# capture can't stream), and show it to the person in one click? Checks, on the real VM:
#   1. the host's enhanced session setting (an enhanced console would take the session away from Moonlight);
#   2. a guest watcher (SYSTEM) that publishes "prompt open" through Hyper-V's data exchange (KVP), and how long the
#      host takes to read it;
#   3. what the Hyper-V console shows when opened while the prompt is up (screenshots), and that closing works.
# Raises a harmless prompt in the guest (cmd.exe asking to run as administrator), then cancels it.
# Run elevated: pwsh -File labs/025-admin-prompt/run.ps1 -Name win10
param(
    [string]$Name = 'win10',
    [string]$OutDir = (Join-Path $PSScriptRoot "out\$(Get-Date -Format 'yyyyMMdd-HHmmss')")
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$tools = Join-Path $PSScriptRoot '..\..\tools\latency'
. (Join-Path $tools 'common.ps1')
if ((Get-VM -Name $Name).State -ne 'Running') { throw "La VM '$Name' está apagada. Ábrela desde GpuVM." }
$vm = Get-LatencyVM -Name $Name
$host_ = Get-VMHost
"enhanced session on host: $($host_.EnableEnhancedSessionMode); VM transport: $((Get-VM $Name).EnhancedSessionTransportType)" | Write-Host

function Read-GuestKvp([string]$Key) {
    $vmId = (Get-VM -Name $Name).Id.Guid.ToUpper()
    $kvp = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_KvpExchangeComponent -Filter "SystemName='$vmId'"
    foreach ($item in $kvp.GuestExchangeItems) {
        $xml = [xml]$item
        $n = $xml.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Name']/VALUE").InnerText
        if ($n -eq $Key) { return $xml.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Data']/VALUE").InnerText }
    }
    $null
}

$results = [ordered]@{}
try {
    # The watcher: one PowerShell loop as SYSTEM, writing GpuVMAdminPrompt = 1/0 to the guest's KVP pool.
    $watcher = @'
$key = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Auto'
$last = $null
while ($true) {
    $open = [bool](Get-Process consent -ErrorAction SilentlyContinue)
    if ($open -ne $last) { Set-ItemProperty -Path $key -Name GpuVMAdminPrompt -Value $(if ($open) { '1' } else { '0' }) -Type String; $last = $open }
    Start-Sleep -Milliseconds 500
}
'@
    Invoke-Command -VMName $Name -Credential $vm.Guest -ArgumentList $watcher -ScriptBlock {
        param($code)
        Set-Content C:\GpuVM\lab025-watcher.ps1 $code -Encoding UTF8
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\GpuVM\lab025-watcher.ps1'
        Register-ScheduledTask -TaskName GpuVM-Lab025Watcher -Action $a -User SYSTEM -RunLevel Highest -Force | Out-Null
        Start-ScheduledTask GpuVM-Lab025Watcher
    }
    Start-Sleep -Seconds 3
    $read = Measure-Command { $before = Read-GuestKvp 'GpuVMAdminPrompt' }
    $results.kvpBefore = $before; $results.kvpReadMs = [math]::Round($read.TotalMilliseconds)
    "kvp before: $before (read in $($results.kvpReadMs) ms)" | Write-Host

    # A harmless prompt, raised in the signed-in user's session.
    $raised = Get-Date
    Invoke-Command -VMName $Name -Credential $vm.Guest -ScriptBlock {
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        Set-Content C:\GpuVM\lab025-prompt.ps1 "Start-Process cmd.exe -ArgumentList '/c exit' -Verb RunAs" -Encoding UTF8
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\GpuVM\lab025-prompt.ps1'
        Register-ScheduledTask -TaskName GpuVM-Lab025Prompt -Action $a -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
        Start-ScheduledTask GpuVM-Lab025Prompt
    }
    $seen = $null
    for ($i = 0; $i -lt 60; $i++) {
        if ((Read-GuestKvp 'GpuVMAdminPrompt') -eq '1') { $seen = [math]::Round(((Get-Date) - $raised).TotalSeconds, 1); break }
        Start-Sleep -Milliseconds 500
    }
    $results.promptSeenSec = $seen
    "host saw the prompt after $seen s" | Write-Host
    Save-ScreenRegion -Path (Join-Path $OutDir '1-moonlight-or-desktop.png')

    # The console, as GpuVM's service would open it (elevated, in this session).
    $opened = Get-Date
    $console = Start-Process (Join-Path $env:SystemRoot 'System32\vmconnect.exe') -ArgumentList 'localhost', $Name -PassThru
    Start-Sleep -Seconds 4
    Save-ScreenRegion -Path (Join-Path $OutDir '2-console-4s.png')
    Start-Sleep -Seconds 4
    Save-ScreenRegion -Path (Join-Path $OutDir '3-console-8s.png')
    $console.Refresh()
    $results.consoleTitle = $console.MainWindowTitle
    "console window: '$($console.MainWindowTitle)'" | Write-Host

    # Cancel the prompt (as nobody answers it) and see the flag go back.
    Invoke-Command -VMName $Name -Credential $vm.Guest -ScriptBlock { Get-Process consent -ErrorAction SilentlyContinue | Stop-Process -Force }
    $cleared = $null
    $t = Get-Date
    for ($i = 0; $i -lt 20; $i++) {
        if ((Read-GuestKvp 'GpuVMAdminPrompt') -eq '0') { $cleared = [math]::Round(((Get-Date) - $t).TotalSeconds, 1); break }
        Start-Sleep -Milliseconds 500
    }
    $results.promptClearedSec = $cleared
    "host saw it closed after $cleared s" | Write-Host
    Stop-Process -Id $console.Id -Force -ErrorAction SilentlyContinue
}
finally {
    Invoke-Command -VMName $Name -Credential $vm.Guest -ScriptBlock {
        foreach ($t in 'GpuVM-Lab025Watcher', 'GpuVM-Lab025Prompt') {
            Stop-ScheduledTask $t -ErrorAction SilentlyContinue
            Unregister-ScheduledTask $t -Confirm:$false -ErrorAction SilentlyContinue
        }
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object CommandLine -like '*lab025*' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
        Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Auto' -Name GpuVMAdminPrompt -ErrorAction SilentlyContinue
        Remove-Item C:\GpuVM\lab025-*.ps1 -ErrorAction SilentlyContinue
    }
    [pscustomobject]$results | ConvertTo-Json | Set-Content (Join-Path $OutDir 'result.json') -Encoding utf8
    "saved $OutDir" | Write-Host
}
