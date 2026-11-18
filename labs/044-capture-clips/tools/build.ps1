# Lab 044: builds the lab's probes (mp4test with the viewer's own MP4 writer, mfprobe) into out\bin.
param(
    # The viewer's source tree (its app\gpuvm holds mp4writer.cpp).
    [string]$Viewer = "$env:USERPROFILE\Desktop\gpuvm-viewer-capture"
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
# libopus from the viewer's prebuilt libraries (the same one it decodes with).
$libs = Join-Path $Viewer 'libs\windows'
Copy-Item (Join-Path $libs 'lib\x64\opus.dll') $bin -Force
$cmd = "`"$vcvars`" x64 >nul && cd /d `"$bin`" && " +
       "cl /nologo /O2 /EHsc /std:c++17 /W3 /I`"$gpuvm`" /I`"$libs\include`" `"$here\mp4test.cpp`" /Fe:mp4test.exe /link /LIBPATH:`"$libs\lib\x64`" >build.log && " +
       "cl /nologo /O2 /EHsc /std:c++17 /W3 `"$here\mfprobe.cpp`" /Fe:mfprobe.exe >>build.log"
cmd /c $cmd
if ($LASTEXITCODE -ne 0) { Get-Content (Join-Path $bin 'build.log'); throw 'build failed' }
Get-ChildItem $bin -Filter *.obj | Remove-Item
"built: $bin"
