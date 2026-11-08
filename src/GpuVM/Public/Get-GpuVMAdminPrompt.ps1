function Get-GpuVMAdminPrompt {
    <#
    .SYNOPSIS
    Windows administrator prompts open in running GpuVM machines captured with WGC (which can't stream them):
    name, prompt id, program and publisher. Light (Hyper-V data exchange, no PowerShell Direct): the app polls it.
    #>
    [CmdletBinding()]
    param()
    foreach ($vm in @(Get-VM | Where-Object State -eq 'Running')) {
        $state = try { Get-GpuVMState -Name $vm.Name } catch { $null }
        if (-not $state -or -not $state['streaming'] -or (Get-GpuVMCaptureMode -State $state) -ne 'wgc') { continue }
        $prompt = try { Get-GuestAdminPrompt -Name $vm.Name } catch { $null }
        if ($prompt) { [ordered]@{ name = $vm.Name; id = $prompt.id; app = $prompt.app; publisher = $prompt.publisher } }
    }
}
