function Invoke-GpuVMAgent {
    <#
    .SYNOPSIS
    Sends one request to the agent inside a machine (methods of docs/agents/protocol.md: screen.capture, input.act,
    ui.tree, exec.run, files.*...) and returns {ok, result, error, ms}. A binary result (a screenshot, a file) is
    saved under ProgramData\GpuVM\agents\blobs and returned as blobPath (deleted after an hour).

    .EXAMPLE
    Invoke-GpuVMAgent -Name test -Method screen.capture -Params @{ maxW = 1280 }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Method,
        [System.Collections.IDictionary]$Params = @{},
        [ValidateRange(1, 600)][int]$TimeoutSec = 30,
        # A file of this PC sent with the request (files.write), 16 MB at most.
        [string]$BlobPath
    )
    $arguments = @{ Name = $Name; Method = $Method; Params = $Params; TimeoutSec = $TimeoutSec }
    if ($BlobPath) {
        $file = Get-Item -LiteralPath $BlobPath -ErrorAction Stop
        if ($file.Length -gt 16MB) { throw 'Files sent with a request are 16 MB at most.' }
        $arguments['Blob'] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file.FullName))
    }
    Invoke-AgentBroker -Command 'Invoke-GpuVMAgent' -Arguments $arguments
}
