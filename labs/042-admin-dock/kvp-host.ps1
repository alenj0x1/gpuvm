# Host side of Hyper-V's data exchange for lab 042 (dot-sourced). The module's own copy lives in
# src/GpuVM/Private/AdminPrompt.ps1; this one stays standalone so the lab runs without importing the module.

function Get-KvpVM([string]$VMName) {
    $id = (Get-VM -Name $VMName -ErrorAction Stop).Id.Guid.ToUpper()
    Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "Name='$id'"
}

function ConvertTo-KvpItemText([string]$Key, [string]$Value) {
    $k = [Security.SecurityElement]::Escape($Key)
    $v = [Security.SecurityElement]::Escape($Value)
    "<INSTANCE CLASSNAME=`"Msvm_KvpExchangeDataItem`"><PROPERTY NAME=`"Data`" TYPE=`"string`"><VALUE>$v</VALUE></PROPERTY><PROPERTY NAME=`"Name`" TYPE=`"string`"><VALUE>$k</VALUE></PROPERTY><PROPERTY NAME=`"Source`" TYPE=`"uint16`"><VALUE>0</VALUE></PROPERTY></INSTANCE>"
}

function Invoke-KvpMethod([string]$VMName, [string]$Method, [string]$Key, [string]$Value) {
    $svc = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService
    $r = Invoke-CimMethod -InputObject $svc -MethodName $Method -Arguments @{ TargetSystem = (Get-KvpVM $VMName); DataItems = @(ConvertTo-KvpItemText $Key $Value) }
    if ($r.ReturnValue -eq 4096) {
        # Asynchronous job: wait for it (usually done in a few ms).
        $job = $r.Job
        for ($i = 0; $i -lt 100; $i++) {
            $j = Get-CimInstance -InputObject $job
            if ($j.JobState -ge 7) { if ($j.JobState -ne 7) { throw "$Method failed: $($j.ErrorDescription)" }; return }
            Start-Sleep -Milliseconds 10
        }
        throw "$Method timed out"
    }
    elseif ($r.ReturnValue -ne 0) { throw "$Method returned $($r.ReturnValue)" }
}

function Set-HostKvpItem([string]$VMName, [string]$Key, [string]$Value, [switch]$Add) {
    if ($Add) {
        try { Invoke-KvpMethod $VMName AddKvpItems $Key $Value; return } catch { }
    }
    Invoke-KvpMethod $VMName ModifyKvpItems $Key $Value
}

function Remove-HostKvpItem([string]$VMName, [string]$Key) {
    Invoke-KvpMethod $VMName RemoveKvpItems $Key ''
}

function Get-GuestKvpItem([string]$VMName, [string]$Key) {
    $id = (Get-VM -Name $VMName).Id.Guid.ToUpper()
    $kvp = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_KvpExchangeComponent -Filter "SystemName='$id'"
    foreach ($item in @($kvp.GuestExchangeItems)) {
        if (-not $item) { continue }
        $xml = [xml]$item
        if ($xml.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Name']/VALUE").InnerText -eq $Key) {
            return $xml.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Data']/VALUE").InnerText
        }
    }
}
