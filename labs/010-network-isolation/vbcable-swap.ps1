# Lab: replaces the VB-CABLE driver inside the VM with another pack (Pack43 to test, Pack45 to revert), the same way
# GpuVM installs it (nefcon). The package folder is copied from this PC.
# pwsh -File vbcable-swap.ps1 -PackageDir <extracted pack> -Inf vbMmeCable64_win7.inf
param(
    [Parameter(Mandatory)][string]$PackageDir,
    [Parameter(Mandatory)][string]$Inf,
    [Parameter(Mandatory)][string]$OutFile,
    [string]$Name = (Get-VM | Where-Object Notes -like "Creada con GpuVM*" | Select-Object -First 1).Name
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\GpuVM\GpuVM.psd1') -Force
$module = Get-Module GpuVM
$log = [System.Collections.Generic.List[string]]::new()
try {
    $state = & $module { param($n) Get-GpuVMState -Name $n } $Name
    $guest = & $module { param($s) Get-GpuVMGuestCredential -State $s } $state
    $session = New-PSSession -VMName $Name -Credential $guest
    $target = 'C:\GpuVM\lab010-vbcable'
    Invoke-Command -Session $session -ArgumentList $target -ScriptBlock { param($t) Remove-Item -Recurse -Force $t -ErrorAction SilentlyContinue; New-Item -ItemType Directory $t | Out-Null }
    Copy-Item -Path (Join-Path $PackageDir '*') -Destination $target -ToSession $session -Recurse
    $out = Invoke-Command -Session $session -ArgumentList $target, $Inf -ScriptBlock {
        param($dir, $inf)
        $nefcon = Get-ChildItem C:\GpuVM -Recurse -Filter nefconw.exe -ErrorAction SilentlyContinue | Where-Object { $_.Directory.Name -eq 'x64' } | Select-Object -First 1
        if (-not $nefcon) { return 'no nefconw' }
        "nefcon: $($nefcon.FullName)"
        $media = '{4d36e96c-e325-11ce-bfc1-08002be10318}'
        $p = Start-Process $nefcon.FullName -ArgumentList '--remove-device-node', '--hardware-id', 'VBAudioVACWDM', '--class-guid', $media -Wait -PassThru -WindowStyle Hidden
        "remove node: $($p.ExitCode)"
        # Driver packages of the cable still in the store.
        $published = (pnputil /enum-drivers) -join "`n" -split "`n`n" | Where-Object { $_ -match 'vbMmeCable' } |
            ForEach-Object { if ($_ -match '(oem\d+\.inf)') { $Matches[1] } }
        foreach ($oem in $published) { "delete $oem : " + ((pnputil /delete-driver $oem /uninstall /force) -join ' ') }
        Start-Sleep -Seconds 3
        $p = Start-Process $nefcon.FullName -ArgumentList 'install', "`"$(Join-Path $dir $inf)`"", 'VBAudioVACWDM' -Wait -PassThru -WindowStyle Hidden
        "install: $($p.ExitCode)"
        Start-Sleep -Seconds 6
        Get-PnpDevice -PresentOnly | Where-Object { $_.FriendlyName -like '*VB-Audio*' -or $_.FriendlyName -like '*CABLE*' } |
            ForEach-Object { "$($_.Status) $($_.Class) $($_.FriendlyName) problem=$($_.Problem)" }
        Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName -like '*VB-Audio*' } | ForEach-Object { "driver $($_.InfName) $($_.DriverVersion)" }
    }
    $out | ForEach-Object { $log.Add([string]$_) }
    Remove-PSSession $session
}
catch { $log.Add("ERROR: $($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)") }
Set-Content -Encoding utf8 -LiteralPath $OutFile -Value $log
