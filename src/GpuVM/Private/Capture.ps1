function Set-GuestCaptureMode {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        [switch]$Restart
    )
    $code = Get-Content -Raw -LiteralPath (Get-RepoPath 'guest\capture-mode.ps1')
    $raw = Invoke-Guest -Name $Name -Credential $Credential -ArgumentList $code, ([bool]$Restart) -ScriptBlock {
        param($code, $restart)
        & ([scriptblock]::Create($code)) -Restart:$restart
    }
    $answer = [string](@($raw)[-1])
    if ($answer -like 'nofork-*') {
        Write-Warning 'GpuVM''s Sunshine capture helper isn''t in this machine: the picture can stay black until GpuVM installs it again.'
        $answer = $answer.Substring(7)
    }
    switch ($answer) {
        'changed' {
            if (-not $Restart) {
                Write-Step 'Sunshine is restarting with its capture helper'
            }
            $true
        }
        'unchanged' { $false }
        default { throw 'Sunshine isn''t installed in the VM.' }
    }
}
