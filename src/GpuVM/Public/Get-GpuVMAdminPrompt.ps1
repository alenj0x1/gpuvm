function Get-GpuVMAdminPrompt {
    <#
    .SYNOPSIS
    Windows administrator prompts open in running GpuVM machines captured with WGC (which can't stream them):
    name, prompt id, program, publisher and whether those two are still being read. Light (Hyper-V data exchange, no
    PowerShell Direct): the app polls it.
    .PARAMETER WithWatched
    Returns { watched, prompts } instead: also how many machines are watched (on, streaming with WGC), so the app's
    notices-only mode knows when to end.
    #>
    [CmdletBinding()]
    param([switch]$WithWatched)
    $watched = 0
    $prompts = foreach ($vm in @(Get-VM | Where-Object State -eq 'Running')) {
        $state = try { Get-GpuVMState -Name $vm.Name } catch { $null }
        if (-not $state -or -not $state['streaming'] -or (Get-GpuVMCaptureMode -State $state) -ne 'wgc') { continue }
        $watched++
        $prompt = try { Get-GuestAdminPrompt -Name $vm.Name } catch { $null }
        if ($prompt) { [ordered]@{ name = $vm.Name; id = $prompt.id; app = $prompt.app; publisher = $prompt.publisher; reading = $prompt.reading } }
    }
    if ($WithWatched) { [ordered]@{ watched = $watched; prompts = @($prompts) } } else { $prompts }
}
