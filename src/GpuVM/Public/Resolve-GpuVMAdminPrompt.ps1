function Resolve-GpuVMAdminPrompt {
    <#
    .SYNOPSIS
    Answers the Windows administrator prompt open in a VM (Allow or Deny), on the person's order from the app.
    -PromptId is the prompt they saw (from Get-GpuVMAdminPrompt); if another one is open by now, nothing is pressed.
    The answer goes through Hyper-V's data exchange with the prompt's one-time code (lab 042, about a second); with a
    watcher from before that, through PowerShell Direct (about 5 s).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Allow', 'Deny')][string]$Answer,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$PromptId
    )
    $reply = if ($Answer -eq 'Allow') { 'yes' } else { 'no' }
    $open = Get-GuestAdminPromptState -Name $Name
    if (-not $open -or $open.id -ne $PromptId) { throw 'The prompt changed or closed. Check the new one before answering.' }
    $result = $null
    if ($open.nonce) { $result = Send-GuestAdminPromptAnswer -Name $Name -Answer $reply -PromptId $PromptId -Nonce $open.nonce }
    if (-not $result) {
        $state = Get-GpuVMState -Name $Name
        $guest = Get-GpuVMGuestCredential -State $state
        if (-not $guest) { throw "GpuVM doesn't have the Windows password for '$Name'." }
        $result = Invoke-GuestAdminPromptAnswer -Name $Name -Credential $guest -Answer $reply -PromptId $PromptId
    }
    if ($result -eq 'changed') { throw 'The prompt changed or closed. Check the new one before answering.' }
    if ($result -ne 'done') { throw "Couldn't answer the prompt: $result" }
    [ordered]@{ name = $Name; answer = $Answer }
}
