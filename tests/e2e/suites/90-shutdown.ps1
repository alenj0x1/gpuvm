function Test-Suite($Ctx) {
    if (-not $Ctx.Machine) { return }
    $vm = Use-Machine $Ctx
    Start-Sleep -Seconds 2
    $pending = $null
    Check-NoFlash 'the agent shutting its machine down' { $script:pending = Start-Tool $Ctx.Mcp 'destroy' @{ machine = $vm; force = $true } } 6000
    $reply = Text-Of (Receive-Mcp $Ctx.Mcp $script:pending)
    Check 'destroy shuts the machine down' ($reply -match 'shut down|deleted') $reply
    $gone = Wait-For { -not (Get-Process GpuVMViewer -ErrorAction SilentlyContinue) } 30
    Check 'its viewer closes' ([bool]$gone) ''
    $leftover = @(Get-AppWindows -Small | Where-Object { (Get-Texts (Get-Element $_.Handle)) -match [regex]::Escape($vm) -or (Get-Texts (Get-Element $_.Handle)) -match 'Recording|Grabando|Take control|Tomar el control' })
    Check 'no notice of it is left on screen' ($leftover.Count -eq 0) "$($leftover.Count) window(s) left"
    Shot 'shutdown-after'
    $Ctx.Machine = $null
}
