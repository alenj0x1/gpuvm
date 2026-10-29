# Extracts each catalog app's own icon from its official installer into app/src/assets/apps/<id>.png (64 px).
# The installers are downloaded and checked (signer, hash) beforehand by whoever runs this; nothing is executed,
# the icon resources are only read. Run on Windows with PowerShell 7:
#   pwsh tools/app-icons/extract.ps1 -InstallerDir <folder with steam.exe, epic.msi, ...>
# Some installers carry a generic setup icon (Chrome, Brave) or a boxed one (Firefox, Spotify); -Source gives those
# the installed program or the publisher's own icon (.exe or .png) instead:
#   -Source @{ chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'; firefox = '<firefox.com favicon>.png' }
param(
    [Parameter(Mandatory)][string]$InstallerDir,
    [hashtable]$Source = @{},
    [int]$Size = 64,
    [string]$OutDir = (Join-Path $PSScriptRoot '..\..\app\src\assets\apps')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace GpuVM -Name IconApi -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern uint PrivateExtractIcons(string file, int index, int cx, int cy, IntPtr[] icons, uint[] ids, uint count, uint flags);
[DllImport("user32.dll")]
public static extern bool DestroyIcon(IntPtr icon);
'@

# The first icon of the file at 256 px (Windows picks the closest size the file has), scaled down smoothly.
function Save-FileIcon {
    param([string]$Path, [string]$Target)
    $handles = [IntPtr[]]::new(1)
    $ids = [uint32[]]::new(1)
    $count = [GpuVM.IconApi]::PrivateExtractIcons($Path, 0, 256, 256, $handles, $ids, 1, 0)
    if ($count -lt 1 -or $handles[0] -eq [IntPtr]::Zero) { throw "Sin ícono: $Path" }
    try {
        $source = [Drawing.Icon]::FromHandle($handles[0]).ToBitmap()
        Save-Scaled -Image $source -Target $Target
        $source.Dispose()
    }
    finally { [void][GpuVM.IconApi]::DestroyIcon($handles[0]) }
}

function Save-Scaled {
    param([Drawing.Image]$Image, [string]$Target)
    $bitmap = [Drawing.Bitmap]::new($Size, $Size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.InterpolationMode = 'HighQualityBicubic'
    $graphics.PixelOffsetMode = 'HighQuality'
    $graphics.DrawImage($Image, 0, 0, $Size, $Size)
    $bitmap.Save($Target, [Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose()
}

# An MSI keeps its icons in the Icon table (ARPPRODUCTICON first); the stream is an .ico or .exe file.
function Export-MsiIcon {
    param([string]$Path, [string]$Target)
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
    $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @('SELECT `Name`, `Data` FROM `Icon`'))
    [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
    $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
    if (-not $record) { throw "El MSI no tiene íconos: $Path" }
    $name = $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, 1)
    $size = $record.GetType().InvokeMember('DataSize', 'GetProperty', $null, $record, 2)
    $data = $record.GetType().InvokeMember('ReadStream', 'InvokeMethod', $null, $record, @(2, $size, 1))
    $bytes = [Text.Encoding]::GetEncoding(28591).GetBytes($data)
    $file = Join-Path ([IO.Path]::GetTempPath()) ("gpuvm-icon-" + [IO.Path]::GetFileName($name))
    if (-not [IO.Path]::GetExtension($file)) { $file += '.ico' }
    [IO.File]::WriteAllBytes($file, $bytes)
    [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
    $file
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$catalog = (Get-Content -Raw (Join-Path $PSScriptRoot '..\..\apps\catalog.json') | ConvertFrom-Json).apps
foreach ($id in $catalog.PSObject.Properties.Name) {
    # An app with its own .svg (Spotify: the green logo, drawn from the publisher's mark) is left as it is.
    if (Test-Path -LiteralPath (Join-Path $OutDir "$id.svg")) { "$id: svg"; continue }
    $target = Join-Path $OutDir "$id.png"
    if ($Source[$id] -and $Source[$id].EndsWith('.png')) {
        $image = [Drawing.Image]::FromFile($Source[$id])
        Save-Scaled -Image $image -Target $target
        $image.Dispose()
        "$id <- $($Source[$id])"
        continue
    }
    if ($Source[$id]) { Save-FileIcon -Path $Source[$id] -Target $target; "$id <- $($Source[$id])"; continue }
    $installer = Get-ChildItem -LiteralPath $InstallerDir -File | Where-Object BaseName -eq $id | Select-Object -First 1
    if (-not $installer) { Write-Warning "Falta el instalador de $id"; continue }
    $file = if ($installer.Extension -eq '.msi') { Export-MsiIcon -Path $installer.FullName } else { $installer.FullName }
    Save-FileIcon -Path $file -Target $target
    "$id <- $($installer.Name)"
}
