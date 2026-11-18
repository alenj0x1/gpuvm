# Lab 044, part 2: how much the recording's sound lags its picture because of the audio path (Opus decode + Windows'
# AAC encoder). A test track beeps exactly at every whole second; it goes through the writer the way the viewer
# records (Opus packets of 5 ms -> AAC), the file's sound is decoded with ffmpeg and each beep's onset is compared
# with its true time. The Opus encoder's own lookahead (6.5 ms) is subtracted: the live stream has it too, so it is
# not the recording's to fix. Writes out\sync-<time>.json.
param([int]$Seconds = 10)
$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot 'out'
$src = Join-Path $out 'src'
$bin = Join-Path $out 'bin'
$beeps = Join-Path $src 'beeps.ogg'
if (-not (Test-Path $beeps)) {
    # 10 ms of 1 kHz at every whole second, silence between.
    & ffmpeg -hide_banner -loglevel error -y -f lavfi -i "aevalsrc='if(lt(mod(t\,1)\,0.01)\,0.8*sin(2*PI*1000*t)\,0)':s=48000:d=$Seconds" -ac 2 -c:a libopus -b:a 128k -frame_duration 5 $beeps
}
$video = Join-Path $src 'in.h264'
$results = @()
# Cases: the Opus packets as received; the shipped AAC path; AAC on a live-like clock (offset, arrival jitter up to
# 3 ms) with the machine silent from 3 to 6 s (no packets: the recorder fills silence and the sound resumes on time).
$cases = @(
    @{ name = 'opus'; args = @('--audio', 'opus') },
    @{ name = 'aac'; args = @('--audio', 'aac') },
    @{ name = 'aac-live-silence'; args = @('--audio', 'aac', '--offset', '60000000', '--jitter', '3000', '--mute-from', '3000', '--mute-to', '6000') }
)
foreach ($case in $cases) {
    $audio = $case.name
    $file = Join-Path $out "sync-$audio.mp4"
    $wav = Join-Path $out "sync-$audio.wav"
    Remove-Item $file, $wav -ErrorAction SilentlyContinue
    $null = & (Join-Path $bin 'mp4test.exe') --codec h264 --video $video --fps 60 --opus $beeps --out $file @($case.args)
    & ffmpeg -hide_banner -loglevel error -y -i $file -vn -c:a pcm_s16le $wav
    $on = (& python -I (Join-Path $PSScriptRoot 'tools\onsets.py') $wav) | ConvertFrom-Json
    # Beeps 1..n-1 (the first second may be cut by the decoder's start).
    $lags = @($on | Where-Object { $_ -gt 500 } | ForEach-Object { $_ - [math]::Round($_ / 1000) * 1000 })
    $mean = ($lags | Measure-Object -Average).Average
    $results += [pscustomobject]@{ audio = $audio; onsetsMs = $on; lagMs = $lags; meanLagMs = [math]::Round($mean, 2) }
    '{0,-5} beeps={1} mean lag {2:N2} ms (min {3:N2}, max {4:N2})' -f $audio, $lags.Count, $mean, ($lags | Measure-Object -Minimum).Minimum, ($lags | Measure-Object -Maximum).Maximum
    Remove-Item $wav
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$results | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out "sync-$stamp.json") -Encoding utf8
"saved out\sync-$stamp.json"
