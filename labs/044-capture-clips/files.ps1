# Lab 044, part 1: the viewer's MP4 writer on its own. Encodes test streams shaped like Sunshine's (no B-frames, one
# key frame every 10 s, Opus in 5 ms packets), writes them through the writer (tools\mp4test, built by
# tools\build.ps1) in each case the viewer meets (start mid-stream, lost frames, 10-bit HDR), and checks every file
# with ffprobe/ffmpeg (decodes cleanly, durations) and Media Foundation (what Windows' players see: tools\mfprobe).
# Writes out\files-<time>.json. Needs ffmpeg on PATH.
param([int]$Seconds = 20)
$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot 'out'
$bin = Join-Path $out 'bin'
$src = Join-Path $out 'src'
New-Item -ItemType Directory -Force $src | Out-Null
foreach ($exe in 'mp4test.exe', 'mfprobe.exe') {
    if (-not (Test-Path (Join-Path $bin $exe))) { throw "Missing ${exe}: run tools\build.ps1 first" }
}

function Encode([string]$name, [string[]]$encodeArgs) {
    $path = Join-Path $src $name
    if (-not (Test-Path $path)) {
        & ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=60:duration=$Seconds" @encodeArgs $path
        if ($LASTEXITCODE) { throw "ffmpeg failed for $name" }
    }
    $path
}
# Sunshine's shape: no B-frames, a key frame only every 10 s (it sends them on request), an AUD per frame.
$h264 = Encode 'in.h264' @('-c:v', 'libx264', '-preset', 'veryfast', '-bf', '0', '-g', '600', '-b:v', '35M', '-bsf:v', 'h264_metadata=aud=insert')
$hevc = Encode 'in.hevc' @('-c:v', 'libx265', '-preset', 'veryfast', '-x265-params', 'bframes=0:keyint=600:aud=1:log-level=error', '-b:v', '35M')
$hdr = Encode 'in-hdr.hevc' @('-pix_fmt', 'yuv420p10le', '-c:v', 'libx265', '-preset', 'veryfast', '-x265-params', 'bframes=0:keyint=600:aud=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:log-level=error', '-b:v', '35M')
$av1 = Encode 'in.obu' @('-c:v', 'av1_nvenc', '-bf', '0', '-g', '600', '-b:v', '20M', '-f', 'obu')
$opus = Join-Path $src 'in.ogg'
if (-not (Test-Path $opus)) {
    & ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=$Seconds" -ac 2 -c:a libopus -b:a 128k -frame_duration 5 $opus
}

$cases = @(
    @{ name = 'h264'; codec = 'h264'; video = $h264 },
    @{ name = 'hevc'; codec = 'hevc'; video = $hevc },
    @{ name = 'hevc-midstream'; codec = 'hevc'; video = $hevc; extra = @('--start', '37') },
    @{ name = 'hevc-loss'; codec = 'hevc'; video = $hevc; extra = @('--drop', '50') },
    @{ name = 'hevc-hdr'; codec = 'hevc'; video = $hdr; extra = @('--hdr', '1') },
    @{ name = 'av1'; codec = 'av1'; video = $av1 },
    @{ name = 'hevc-noaudio'; codec = 'hevc'; video = $hevc; noAudio = $true }
)
$results = @()
foreach ($c in $cases) {
    $file = Join-Path $out "$($c.name).mp4"
    Remove-Item $file -ErrorAction SilentlyContinue
    $writeArgs = @('--codec', $c.codec, '--video', $c.video, '--fps', '60', '--out', $file)
    if (-not $c.noAudio) { $writeArgs += @('--opus', $opus) }
    if ($c.extra) { $writeArgs += $c.extra }
    $write = (& (Join-Path $bin 'mp4test.exe') @writeArgs) | ConvertFrom-Json
    $probe = & ffprobe -v error -show_entries 'format=duration:stream=codec_name,codec_tag_string,width,height,color_transfer,duration,nb_frames' -of json $file | ConvertFrom-Json
    $decodeErrors = (& ffmpeg -hide_banner -v error -i $file -fps_mode passthrough -f null - 2>&1 | Where-Object { "$_" -notmatch 'non monotonically increasing dts' } | Measure-Object -Line).Lines
    $mf = (& (Join-Path $bin 'mfprobe.exe') $file) | ConvertFrom-Json
    $results += [pscustomobject]@{ case = $c.name; write = $write; ffprobe = $probe; ffmpegDecodeErrorLines = $decodeErrors; mf = $mf }
    $v = $mf.streams | Where-Object kind -eq 'video'
    $a = $mf.streams | Where-Object kind -eq 'audio'
    '{0,-15} write={1} {2:N1} MB {3:N1} s | ffmpeg errors={4} | MF open={5} dur={6:N1} video {7} dec={8} seek={9} audio {10} dec={11}' -f $c.name, $write.ok, ((Get-Item $file).Length / 1MB), ($write.durationMs / 1000), $decodeErrors, $mf.open, $mf.durationS, $v.codec, $v.decodable, $v.seek, $a.codec, $a.decodable
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$results | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $out "files-$stamp.json") -Encoding utf8
"saved out\files-$stamp.json"
