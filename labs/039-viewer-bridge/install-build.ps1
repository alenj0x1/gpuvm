# Lab 039 helper: installs the latest build without the installer's pages (NSIS /S) and opens GpuVM again. The app
# is ended without its quit handler, so the machines keep running.
# - Run as administrator: the installer is first copied to a folder only administrators can write
#   (a new random folder under Program Files) and runs from there, so nothing running as the user can swap it between the copy and
#   the run.
# - Run as the user: a one-shot task of this user asks for UAC on the real desktop (a sandboxed shell can't). The
#   prompt stays on purpose: the service only trusts the gpuvm.exe in Program Files, and anything that installed
#   there without it would let any program do the same.
param([string]$Setup = (Join-Path $PSScriptRoot '..\..\app\src-tauri\target\release\bundle\nsis\GpuVM_0.8.0_x64-setup.exe'))
$Setup = (Resolve-Path $Setup).Path
Get-Process gpuvm, GpuVMViewer -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800
$before = (Get-FileHash 'C:\Program Files\GpuVM\gpuvm.exe').Hash
$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$code = $null
if ($elevated) {
    # A new folder with a random name under Program Files, where only administrators can create anything (under
    # ProgramData any user could create the folder first and keep rights over it as its owner).
    $safe = Join-Path $env:ProgramFiles ('GpuVM-lab-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $safe -ErrorAction Stop | Out-Null
    try {
        # Administrators and SYSTEM only, owned by Administrators, nothing inherited.
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
        foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        }
        Set-Acl -Path $safe -AclObject $acl
        $copy = Join-Path $safe 'GpuVM-setup.exe'
        Copy-Item -LiteralPath $Setup -Destination $copy
        # The copy is the build that was asked for.
        if ((Get-FileHash -LiteralPath $copy).Hash -ne (Get-FileHash -LiteralPath $Setup).Hash) { throw 'the installer copy differs from the build' }
        $p = Start-Process -FilePath $copy -ArgumentList '/S' -PassThru; $p.WaitForExit(); $code = $p.ExitCode
    } finally { Remove-Item -LiteralPath $safe -Recurse -Force -ErrorAction SilentlyContinue }
} else {
    $done = Join-Path $env:TEMP ('gpuvm-install-' + [guid]::NewGuid().ToString('N') + '.txt')
    # Paths go into a single-quoted string of the task's command: their quotes doubled.
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
    $cmd = "try { `$p = Start-Process -FilePath $(& $q $Setup) -ArgumentList '/S' -Verb RunAs -PassThru -ErrorAction Stop; `$p.WaitForExit(); `$p.ExitCode } catch { 'declined' } | Set-Content -LiteralPath $(& $q $done)"
    $name = 'GpuVM-lab-install-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $pwsh = (Get-Command pwsh).Source
    try {
        Register-ScheduledTask -TaskName $name -Action (New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -WindowStyle Hidden -Command $cmd") -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries) | Out-Null
        Start-ScheduledTask -TaskName $name
        $deadline = (Get-Date).AddMinutes(4)
        while (-not (Test-Path $done) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    } finally { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue }
    $code = if (Test-Path $done) { (Get-Content $done) -join ''; Remove-Item $done } else { 'no answer' }
}
$after = (Get-FileHash 'C:\Program Files\GpuVM\gpuvm.exe').Hash
"installer: $code; gpuvm.exe $(if ($before -eq $after) { 'unchanged' } else { 'replaced' })"
& (Join-Path $PSScriptRoot 'run-build.ps1') -Installed
