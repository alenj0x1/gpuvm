# Lab 063: puts a guest agent build (guest\agent\dist\gpuvm-agent.exe) in a running agent machine in place: stops
# the GpuVMAgent service and its helpers, swaps the exe (the first swap keeps the machine's own as .orig063), sets
# the unfinished-frame check's off flag (-CheckOff) or removes it, starts the service and waits for the agent to
# answer. -Restore puts the machine's own agent back. Run elevated.
param([Parameter(Mandatory)][string]$Name, [string]$Agent, [switch]$CheckOff, [switch]$Restore)
. (Join-Path $PSScriptRoot 'common.ps1')
$cred = Get-Lab063Cred $Name
$s = New-PSSession -VMName $Name -Credential $cred
try {
    if ($Agent) { Copy-Item -ToSession $s -Path $Agent -Destination 'C:\Windows\Temp\gpuvm-agent-lab063.exe' -Force }
    Invoke-Command -Session $s -ArgumentList @([bool]$Agent, $CheckOff.IsPresent, $Restore.IsPresent) {
        param($new, $checkOff, $restore)
        $dir = 'C:\Program Files\GpuVM Agent'
        $exe = "$dir\gpuvm-agent.exe"
        if (-not (Test-Path "$exe.orig063")) { Copy-Item $exe "$exe.orig063" }
        if ($checkOff -and -not $restore) { Set-Content "$dir\frame-check-off.txt" 'off' } else { Remove-Item "$dir\frame-check-off.txt" -ErrorAction SilentlyContinue }
        $src = if ($restore) { "$exe.orig063" } elseif ($new) { 'C:\Windows\Temp\gpuvm-agent-lab063.exe' } else { $null }
        Stop-Service GpuVMAgent -Force
        Get-Process gpuvm-agent -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep 1
        if ($src) { Copy-Item $src $exe -Force }
        if ($restore) { Remove-Item "$exe.orig063", 'C:\Windows\Temp\gpuvm-agent-lab063.exe' -Force -ErrorAction SilentlyContinue }
        Start-Service GpuVMAgent
    }
    Import-Module 'C:\Program Files\GpuVM\gpuvm\src\GpuVM\GpuVM.psd1' -Force
    $w = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep 2
        $v = try { (Invoke-GpuVMAgent -Name $Name -Method exec.run -Params @{ file = 'C:\Program Files\GpuVM Agent\gpuvm-agent.exe'; args = @('version') }).result.stdout.Trim() } catch { $null }
    } until ($v -or $w.Elapsed.TotalSeconds -gt 90)
    "agent $v answering after $([int]$w.Elapsed.TotalSeconds) s; check $(if ($CheckOff -and -not $Restore) { 'off' } else { 'on' })"
}
finally { Remove-PSSession $s }
