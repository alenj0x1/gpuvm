# Lab 025, third pass. Turns off enhanced session mode on the host (GpuVM VMs
# stream through Moonlight and an enhanced console takes their session away), then:
#   - opens the console while an administrator prompt is up in the VM: it should show the VM's screen directly;
#   - finds out how a value written in the guest reaches the host's KVP list (wait, service restart).
# Run elevated: pwsh -File labs/025-admin-prompt/diag2.ps1 -Name win10
param(
    [string]$Name = 'win10',
    [string]$OutDir = (Join-Path $PSScriptRoot "out\diag2-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$tools = Join-Path $PSScriptRoot '..\..\tools\latency'
. (Join-Path $tools 'common.ps1')
if ((Get-VM -Name $Name).State -ne 'Running') { throw "La VM '$Name' está apagada. Ábrela desde GpuVM." }
$vm = Get-LatencyVM -Name $Name

function Get-GuestKvp {
    $vmId = (Get-VM -Name $Name).Id.Guid.ToUpper()
    $kvp = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_KvpExchangeComponent -Filter "SystemName='$vmId'"
    @(foreach ($item in @($kvp.GuestExchangeItems)) {
        if (-not $item) { continue }
        $xml = [xml]$item
        '{0}={1}' -f $xml.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Name']/VALUE").InnerText, $xml.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Data']/VALUE").InnerText
    }) -join ' '
}

Set-VMHost -EnableEnhancedSessionMode $false
. (Join-Path $tools 'input-meter.ps1')
"enhanced session on host: $((Get-VMHost).EnableEnhancedSessionMode)" | Write-Host
try {
    $where = Invoke-Command -VMName $Name -Credential $vm.Guest -ScriptBlock {
        $key = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest'
        if (-not (Test-Path $key)) { New-Item -Path $key | Out-Null }
        Set-ItemProperty -Path $key -Name GpuVMLabTest -Value 'hello' -Type String
        (Get-Item $key).Property -join ','
    }
    "guest Guest key values: $where" | Write-Host
    foreach ($wait in 5, 10) { Start-Sleep -Seconds $wait; "host kvp after $wait s more: $(Get-GuestKvp)" | Write-Host }
    Invoke-Command -VMName $Name -Credential $vm.Guest -ScriptBlock { Restart-Service vmickvpexchange -Force }
    Start-Sleep -Seconds 5
    "host kvp after restarting the guest KVP service: $(Get-GuestKvp)" | Write-Host
    Invoke-Command -VMName $Name -Credential $vm.Guest -ScriptBlock { Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest' -Name GpuVMLabTest -Value 'changed' -Type String }
    Start-Sleep -Seconds 3
    "host kvp 3 s after changing the value: $(Get-GuestKvp)" | Write-Host

    Invoke-Command -VMName $Name -Credential $vm.Guest -ScriptBlock {
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        Set-Content C:\GpuVM\lab025-prompt.ps1 "Start-Process cmd.exe -ArgumentList '/c exit' -Verb RunAs" -Encoding UTF8
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\GpuVM\lab025-prompt.ps1'
        Register-ScheduledTask -TaskName GpuVM-Lab025Prompt -Action $a -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
        Start-ScheduledTask GpuVM-Lab025Prompt
    }
    Start-Sleep -Seconds 4
    $opened = Get-Date
    $console = Start-Process (Join-Path $env:SystemRoot 'System32\vmconnect.exe') -ArgumentList 'localhost', $Name -PassThru
    # Its window in front (as GpuVM will do), as soon as it exists.
    for ($i = 0; $i -lt 40 -and -not $console.MainWindowHandle; $i++) { Start-Sleep -Milliseconds 100; $console.Refresh() }
    "console window after $([math]::Round(((Get-Date) - $opened).TotalSeconds, 1)) s; in front: $([GpuVMInputMeter]::BringToFront($console.MainWindowHandle))" | Write-Host
    Start-Sleep -Seconds 3
    Save-ScreenRegion -Path (Join-Path $OutDir 'console-3s.png')
    Start-Sleep -Seconds 4
    Save-ScreenRegion -Path (Join-Path $OutDir 'console-7s.png')
    Stop-Process -Id $console.Id -Force -ErrorAction SilentlyContinue
}
finally {
    Invoke-Command -VMName $Name -Credential $vm.Guest -ScriptBlock {
        Get-Process consent -ErrorAction SilentlyContinue | Stop-Process -Force
        Stop-ScheduledTask GpuVM-Lab025Prompt -ErrorAction SilentlyContinue
        Unregister-ScheduledTask GpuVM-Lab025Prompt -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item C:\GpuVM\lab025-*.ps1 -ErrorAction SilentlyContinue
        Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest' -Name GpuVMLabTest -ErrorAction SilentlyContinue
    }
    "saved $OutDir (enhanced session stays off on the host)" | Write-Host
}
