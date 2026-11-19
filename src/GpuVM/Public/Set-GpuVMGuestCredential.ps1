function Set-GpuVMGuestCredential {
    <#
    .SYNOPSIS
    Saves the guest account (DPAPI-encrypted) so GpuVM can fix things inside the VM
    via PowerShell Direct, without networking and without user action.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    Assert-Admin
    $state = Get-GpuVMState -Name $Name
    if ((Get-VM -Name $Name).State -eq 'Running') {
        try { Invoke-Command -VMName $Name -Credential $Credential -ScriptBlock { $true } -ErrorAction Stop | Out-Null }
        catch {
            $message = $_.Exception.Message
            if ($message -match 'password|contraseña|credential|credencial|logon|inicio de sesión') { throw 'The password isn''t right for the VM''s account.' }
            throw "Couldn't check the password inside the VM (is it still starting?): $message"
        }
    }
    $state['guest'] = [ordered]@{
        user     = $Credential.UserName
        password = $Credential.Password | ConvertFrom-SecureString
    }
    Save-GpuVMState $state
    [ordered]@{ name = $Name; guestCredential = $true }
}

function Get-GpuVMGuestCredential {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    if (-not $State['guest']) { return $null }
    [pscredential]::new($State['guest']['user'], (ConvertTo-SecureString $State['guest']['password']))
}
