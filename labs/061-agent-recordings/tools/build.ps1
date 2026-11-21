# Lab 061: builds rectest (the viewer's light recorder and MP4 writer on their own) into out\bin.
param(
    # The viewer's source tree (its app\gpuvm holds transcoder.cpp).
    [string]$Viewer = "$env:USERPROFILE\Desktop\gpuvm-viewer-recordings"
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$bin = Join-Path $here '..\out\bin'
New-Item -ItemType Directory -Force $bin | Out-Null
$bin = (Resolve-Path $bin).Path
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -property installationPath
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
$gpuvm = Join-Path $Viewer 'app\gpuvm'
$limelight = Join-Path $Viewer 'moonlight-common-c\moonlight-common-c\src'
$libs = Join-Path $Viewer 'libs\windows'
# The viewer's own FFmpeg (decoders only) and libopus.
foreach ($dll in 'opus.dll', 'avcodec-63.dll', 'avutil-61.dll', 'dav1d.dll') {
    Copy-Item (Join-Path $libs "lib\x64\$dll") $bin -Force
}
$cmd = "`"$vcvars`" x64 >nul && cd /d `"$bin`" && " +
       "cl /nologo /O2 /EHsc /std:c++17 /W3 /utf-8 /I`"$gpuvm`" /I`"$libs\include`" /I`"$libs\include\x64`" /I`"$limelight`" " +
       "`"$here\rectest.cpp`" /Fe:rectest.exe /link /LIBPATH:`"$libs\lib\x64`" >build.log"
cmd /c $cmd
if ($LASTEXITCODE -ne 0) { Get-Content (Join-Path $bin 'build.log'); throw 'build failed' }
Get-ChildItem $bin -Filter *.obj | Remove-Item
"built: $bin"
