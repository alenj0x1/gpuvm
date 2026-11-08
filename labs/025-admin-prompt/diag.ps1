# Lab 025, second pass: why the host read no KVP value, whether the prompt really opened, and whether the console
# opens straight to the VM's screen (no "Display configuration" question) when enhanced session is off for this VM
# only (the guest's vmicrdv service; restored at the end). Run elevated:
#   pwsh -File labs/025-admin-prompt/diag.ps1 -Name win10
param(
    [string]$Name = 'win10',
    [string]$OutDir = (Join-Path $PSScriptRoot "out\diag-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$tools = Join-Path $PSScriptRoot '..\..\tools\latency'
. (Join-Path $tools 'common.ps1')
if ((Get-VM -Name $Name).State -ne 'Running') { throw "La VM '$Name' está apagada. Ábrela desde GpuVM." }
$vm = Get-LatencyVM -Name $Name
Get-VMIntegrationService -VMName $Name | ForEach-Object { "integration: $($_.Name) enabled=$($_.Enabled) status=$($_.PrimaryStatusDescription)" } | Write-Host

function Get-GuestKvp {
    $vmId = (Get-VM -Name $Name).Id.Guid.ToUpper()
    $kvp = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_KvpExchangeComponent -Filter "SystemName='$vmId'"
    $map = [ordered]@{}
    foreach ($item in @($kvp.GuestExchangeItems)) {
        if (-not $item) { continue }
        $xml = [xml]$item
        $map[$xml.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Name']/VALUE").InnerText] = $xml.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Data']/VALUE").InnerText
    }
    $map
}

$rdv = $null
try {
    $guest = Invoke-Command -VMName $Name -Credential $vm.Guest -ScriptBlock {
        $key = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Auto'
        # New-Item only when missing: -Force on an existing key would wipe its values.
        if (-not (Test-Path $key)) { New-Item -Path $key | Out-Null }
        Set-ItemProperty -Path $key -Name GpuVMLabTest -Value 'hello' -Type String
        [pscustomobject]@{
            services = (Get-Service vmic* | ForEach-Object { "$($_.Name)=$($_.Status)/$($_.StartType)" }) -join ' '
            kvp = (Get-Service vmickvpexchange).Status.ToString()
            rdv = (Get-Service vmicrdv).Status.ToString()
            rdvStart = (Get-Service vmicrdv).StartType.ToString()
            prompt = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System').PromptOnSecureDesktop
        }
    }
    $rdv = $guest
    "guest services: $($guest.services)" | Write-Host
    "guest: vmickvpexchange=$($guest.kvp) vmicrdv=$($guest.rdv)/$($guest.rdvStart) PromptOnSecureDesktop=$($guest.prompt)" | Write-Host
    Start-Sleep -Seconds 3
    "host kvp after writing GpuVMLabTest: $((Get-GuestKvp).GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })" | Write-Host

    # Raise the prompt and look at it from inside.
    Invoke-Command -VMName $Name -Credential $vm.Guest -ScriptBlock {
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        Set-Content C:\GpuVM\lab025-prompt.ps1 "Start-Process cmd.exe -ArgumentList '/c exit' -Verb RunAs" -Encoding UTF8
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\GpuVM\lab025-prompt.ps1'
        Register-ScheduledTask -TaskName GpuVM-Lab025Prompt -Action $a -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
        Start-ScheduledTask GpuVM-Lab025Prompt
    }
    Start-Sleep -Seconds 4
    $consent = Invoke-Command -VMName $Name -Credential $vm.Guest -ScriptBlock { @(Get-Process consent -ErrorAction SilentlyContinue).Count }
    "consent.exe processes in the guest: $consent" | Write-Host

    # Enhanced session off for this VM only, then the console.
    Invoke-Command -VMName $Name -Credential $vm.Guest -ScriptBlock { Stop-Service vmicrdv -Force; Set-Service vmicrdv -StartupType Disabled }
    Start-Sleep -Seconds 2
    $console = Start-Process (Join-Path $env:SystemRoot 'System32\vmconnect.exe') -ArgumentList 'localhost', $Name -PassThru
    Start-Sleep -Seconds 5
    Save-ScreenRegion -Path (Join-Path $OutDir 'console-basic-5s.png')
    Start-Sleep -Seconds 4
    Save-ScreenRegion -Path (Join-Path $OutDir 'console-basic-9s.png')
    Stop-Process -Id $console.Id -Force -ErrorAction SilentlyContinue
}
finally {
    Invoke-Command -VMName $Name -Credential $vm.Guest -ArgumentList $rdv -ScriptBlock {
        param($rdv)
        Get-Process consent -ErrorAction SilentlyContinue | Stop-Process -Force
        Stop-ScheduledTask GpuVM-Lab025Prompt -ErrorAction SilentlyContinue
        Unregister-ScheduledTask GpuVM-Lab025Prompt -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item C:\GpuVM\lab025-*.ps1 -ErrorAction SilentlyContinue
        Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Auto' -Name GpuVMLabTest -ErrorAction SilentlyContinue
        if ($rdv) {
            Set-Service vmicrdv -StartupType $rdv.rdvStart
            if ($rdv.rdv -eq 'Running') { Start-Service vmicrdv }
        }
    }
    "restored; saved $OutDir" | Write-Host
}
