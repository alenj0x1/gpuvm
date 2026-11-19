function Send-GpuVMFile {
    <#
    .SYNOPSIS
    Copies files and folders into a running VM: to Desktop\Received of the user signed in there. From this PC
    (-Path), or from another running VM (-FromVM with paths inside it), passing through this PC's memory only: nothing
    is written to its disk. Nothing ever goes from a VM to this PC.
    .EXAMPLE
    Send-GpuVMFile -Name win10 -Path 'C:\Users\me\Pictures\foto.png', 'D:\Proyecto'
    .EXAMPLE
    Send-GpuVMFile -Name win11 -FromVM win10 -Path 'C:\Users\gpuvm\Desktop\informe.docx'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Path,
        [string]$FromVM,
        # Folder on the VM's desktop.
        [ValidatePattern('^(?!\.{1,2}$)(?!.*[. ]$)[^\\/:*?"<>|\x00-\x1f]{1,60}$')][string]$Folder = 'Received',
        # Lets Stop-GpuVMTransfer cancel it.
        [ValidatePattern('^[a-f0-9]{8,32}$')][string]$TransferId = ([guid]::NewGuid().ToString('n'))
    )
    Assert-Admin
    if ($FromVM -and $FromVM -eq $Name) { throw 'Choose another machine to send to.' }
    $target = Open-TransferSession -Name $Name
    $source = $null
    $marker = Get-TransferMarker -Id $TransferId
    $receiving = $false
    try {
        if ($FromVM) {
            $source = Open-TransferSession -Name $FromVM
            Write-Step "Measuring in $FromVM"
            $list = Get-GuestTransferEntries -Session $source -Path $Path
        }
        else {
            Write-Step 'Measuring'
            $list = Get-HostTransferEntries -Path $Path
        }
        $entries = $list.Entries
        $total = [int64]($entries | Measure-Object -Property Size -Sum).Sum
        $files = @($entries | Where-Object { -not $_.Dir }).Count
        $receiver = Open-GuestReceiver -Session $target -Id $TransferId -Folder $Folder
        $receiving = $true
        # Room for the copy and for the VM to keep working.
        if ($total + 512MB -gt $receiver.Free) {
            throw "It doesn't fit: it's $([math]::Ceiling($total / 1MB)) MB and $Name has $([math]::Floor($receiver.Free / 1MB)) MB free."
        }
        $pipe = New-TransferPipe -Session $target -Id $TransferId -Total $total -Marker $marker
        $buffer = [byte[]]::new($script:TransferChunk)
        $big = [System.Collections.Generic.List[object]]::new()
        # From another VM, small files are read several per round trip (up to 4 MB): one each took ~0.1 s.
        $batch = [System.Collections.Generic.List[object]]::new()
        $batchBytes = [int64]0
        foreach ($entry in $entries) {
            if ($entry.Dir) { Write-TransferBytes -Pipe $pipe -Bytes (New-TarHeader -Name $entry.Rel -Directory); continue }
            if ($entry.Size -ge $script:TransferDirectMin) { $big.Add($entry); continue }
            if ($FromVM) {
                $batch.Add($entry); $batchBytes += $entry.Size
                if ($batchBytes -ge $script:TransferChunk -or $batch.Count -ge 500) {
                    Copy-GuestFilesToPipe -Session $source -Entries $batch.ToArray() -Pipe $pipe
                    $batch.Clear(); $batchBytes = 0
                }
                continue
            }
            Write-TransferBytes -Pipe $pipe -Bytes (New-TarHeader -Name $entry.Rel -Size $entry.Size)
            # With the person's rights, and only if still under the folder that was checked (UserFiles.cs).
            try { $stream = [GpuVM.UserFiles]::OpenFile($entry.Full, $entry.Root) }
            catch [Management.Automation.MethodInvocationException] { throw (Get-InnerMessage $_) }
            try {
                $left = $entry.Size
                while ($left -gt 0 -and ($n = $stream.Read($buffer, 0, [int][math]::Min($buffer.Length, $left))) -gt 0) {
                    Write-TransferBytes -Pipe $pipe -Bytes $buffer -Count $n
                    $left -= $n
                }
                # The archive says how long the file is: one that shrank while it was read can't be completed.
                if ($left -ne 0) { throw "$($entry.Rel) changed while it was sent; try again." }
            }
            finally { $stream.Dispose() }
            $pad = (512 - ($entry.Size % 512)) % 512
            if ($pad) { Write-TransferBytes -Pipe $pipe -Bytes ([byte[]]::new($pad)) }
        }
        if ($batch.Count) { Copy-GuestFilesToPipe -Session $source -Entries $batch.ToArray() -Pipe $pipe }
        # The end of a tar archive: two empty blocks.
        Write-TransferBytes -Pipe $pipe -Bytes ([byte[]]::new(1024))
        Send-TransferChunk -Pipe $pipe
        if ($big.Count) { Copy-TransferBigFiles -Name $Name -FromVM $FromVM -Big $big.ToArray() -Staging $receiver.Staging -Pipe $pipe }
        $receiving = $false
        $done = Close-GuestReceiver -Session $target -Id $TransferId
        Assert-TransferArrived -Done $done -Bytes $total -Files $files -Name $Name
        Write-Step "Ready on $Name's desktop, in $Folder"
        if ($list.Skipped) { Write-Warning "$($list.Skipped) links (shortcuts to other folders) were skipped." }
        [ordered]@{ name = $Name; from = $FromVM; folder = $Folder; path = $done.Dest; items = @($done.Names); files = $files; bytes = $total }
    }
    catch [OperationCanceledException] {
        throw 'Copy cancelled.'
    }
    finally {
        if ($receiving) { try { $null = Close-GuestReceiver -Session $target -Id $TransferId -Cancel } catch { } }
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        Remove-PSSession $target -ErrorAction SilentlyContinue
        if ($source) { Remove-PSSession $source -ErrorAction SilentlyContinue }
    }
}
