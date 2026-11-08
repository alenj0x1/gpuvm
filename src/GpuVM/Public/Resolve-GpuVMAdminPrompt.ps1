function Resolve-GpuVMAdminPrompt {
    <#
    .SYNOPSIS
    Answers the Windows administrator prompt open in a VM (Allow or Deny), on the person's order from the app.
    -PromptId is the prompt they saw (from Get-GpuVMOverview); if another one is open by now, nothing is pressed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Allow', 'Deny')][string]$Answer,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$PromptId
    )
    $state = Get-GpuVMState -Name $Name
    $guest = Get-GpuVMGuestCredential -State $state
    if (-not $guest) { throw "Falta la contraseña de Windows de '$Name' en GpuVM." }
    $result = Invoke-GuestAdminPromptAnswer -Name $Name -Credential $guest -Answer $(if ($Answer -eq 'Allow') { 'yes' } else { 'no' }) -PromptId $PromptId
    if ($result -eq 'changed') { throw 'El aviso ya cambió o se cerró. Revisa el nuevo antes de responder.' }
    if ($result -ne 'done') { throw "No se pudo responder el aviso: $result" }
    [ordered]@{ name = $Name; answer = $Answer }
}
