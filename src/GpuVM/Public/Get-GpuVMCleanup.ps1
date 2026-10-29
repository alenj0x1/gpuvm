function Get-GpuVMCleanup {
    <#
    .SYNOPSIS
    The Windows cleanup levels (guest/cleanup.ps1) with what each one adds, for choosing one.
    #>
    [CmdletBinding()]
    param()
    # Only data and function definitions: loading it changes nothing on this computer.
    . (Get-RepoPath 'guest\cleanup.ps1')
    foreach ($level in $GpuVMCleanupLevels) {
        [ordered]@{
            id    = $level
            name  = $GpuVMCleanupLevelNames[$level]
            items = @(foreach ($name in $GpuVMCleanup.Keys) {
                    if ($GpuVMCleanup[$name]['Level'] -eq $level) { [ordered]@{ id = $name; description = $GpuVMCleanup[$name]['Description'] } }
                })
        }
    }
}
