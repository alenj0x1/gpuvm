# Lab 044 notes

**Goal:** screenshots, recordings and the last 30 s of the machine's picture, from the viewer's side panel, at no
visible cost to the stream, in files that common players open.

## Nov 18, 2026: what the viewer has to work with

- The FFmpeg the viewer ships (avformat-63, avcodec-63) has **no muxers, no encoders and no bitstream filters**
  (`av_muxer_iterate`, `av_codec_iterate` for encoders and `av_bsf_iterate` return nothing). So the MP4 writer is our
  own (`gpuvm-viewer` `app/gpuvm/mp4writer.cpp`: fragmented MP4, avcC/hvcC/av1C from the stream's first key frame,
  colr from the stream's colorimetry, an mfra index of key frames, duration patched on close).
- Sunshine sends key frames only on request (an infinite GOP). Recording asks for one when it starts, and while
  recording or keeping the last 30 s the viewer asks for one when the stream hasn't had one for 10 s, so files can be
  seeked and the buffer can start at most ~10 s before its 30 s.
- His stream (win-gpu): HEVC Main (format 0x100), 1920x1080 at 180 FPS, 35 Mb/s, stereo Opus in 5 ms packets.
- This PC's Windows has **no HEVC Video Extension and no AV1 Video Extension**: Windows' own players (Películas y TV,
  Reproductor multimedia) can't decode HEVC or AV1 here, whatever the container. H.264 they play. Open question for
  him (see the end).

## Part 1: the files (`files.ps1`, `out/files-20261118-071854.json`)

20 s test streams shaped like Sunshine's (1080p60, no B-frames, one key frame, Opus 5 ms packets), written through the
viewer's own writer by `tools/mp4test` exactly as the recorder does (Opus decoded and encoded as AAC).

| Case | MB | Duration | ffmpeg full decode | Media Foundation: video / sound / seek |
|---|---|---|---|---|
| H.264 | 83.1 | 20.0 s | 0 errors | H264 decodes / AAC decodes / yes |
| HEVC | 83.8 | 20.0 s | 0 errors | HEVC opens, no decoder installed / AAC decodes / yes |
| HEVC, recording starts mid-stream (frame 37) | 42.1 | 10.0 s | 0 errors | starts at the next key frame (10 s later) / yes / yes |
| HEVC, every 50th frame lost | 82.2 | 20.0 s | 2156 error lines (expected: references missing without RFI) | opens / yes / yes |
| HEVC Main 10, HDR10 | 83.9 | 20.0 s | 0 errors, tagged bt2020 / smpte2084 | opens / yes / yes |
| AV1 (NVENC) | 50.3 | 20.0 s | 0 errors | AV1 opens, no decoder installed / AAC decodes / yes |
| HEVC, no sound | 83.4 | 20.0 s | 0 errors | opens / - / yes |

- **Opus inside MP4 is not decodable by Media Foundation** on this Windows (first run, `out/files-20261118-071208.json`:
  every file's sound "Opus, decodable false"). Windows' AAC encoder (Media Foundation, part of Windows) is used
  instead: AAC-LC 192 kb/s, decodes everywhere. Cost: one Opus decode + one AAC encode of 48 kHz stereo on the
  writer's thread, never on the stream's threads.
- Writing 20 s of 35 Mb/s takes 80-560 ms (the first case includes the encoder's start): the writer keeps up ~40x.
- Lost frames: the file holds exactly what arrived; a player shows the same damage the live picture had until the next
  key frame. In the live stream Sunshine's reference-frame invalidation repairs it, and the next 10 s key frame too.

## Part 2: sound on the picture (`sync.ps1`, `out/sync-20261118-071920.json`)

A track beeping at every whole second, through the same path, decoded by ffmpeg, onsets compared with the true times
(9 beeps each, identical every beep):

| Sound in the file | Lag |
|---|---|
| Opus as received | -2.5 ms |
| AAC (Windows' encoder, the shipped path) | +2.5 ms |

Windows' encoder stamps its frames for its own priming: no correction needed (lip sync is noticed beyond ~20-40 ms).
The live sound and picture keep their relation: the recording puts each sound packet at its arrival time on the
picture's clock (host presentation time + the smallest delay seen between host and here).

Later the same day the sound path became `RecordFile` (viewer `app/gpuvm/recordfile.cpp`, run as is by `tools/mp4test`):
the machine sends no sound packets while it is quiet, so stretches without sound are filled with real silence and,
when sound comes back, silence goes exactly up to it. `out/sync-20261118-091237.json`, live-like clock (offset,
arrival jitter up to 3 ms), silent from 3 to 6 s:

| Sound in the file | Lag (beeps after the silence too) |
|---|---|
| AAC, live-like with a silent stretch | +0.9 to +2.5 ms (mean +1.5) |

## Nov 18, 2026: the first live recording had an empty sound track

The installed app's first recording of win-gpu (a quiet desktop, 52 s, 155 MB) played in ffmpeg but Media Foundation
refused it (`c00d36c4`). ffmpeg remuxes isolated it: the video alone opened, the sound alone didn't. The recorder's own
log line (added for this) said `audio in 0`: **Sunshine sends no sound packets while nothing plays**, so the AAC track
had no samples. Every synthetic test had continuous sound. Fixed with the silence fill above; the next real recording
(23 s, quiet desktop) opened in Media Foundation with AAC decodable and seekable. ffmpeg's `-f null` check printed
"non monotonically increasing dts" for 180 FPS streams (two frames 2.6 ms apart land in one 1/180 s slot of its
output): the file's timestamps are strictly increasing (min step 230/90000 s); the lab now ignores that warning.

## Part 3: live costs (`run.ps1`, `out/run-20261118-104855.json`)

win-gpu, HEVC 1920x1080 at 180 FPS, 35 Mb/s cap, borderless; the viewer driven through its pipe like the app does.
2 interleaved rounds, 15 s of motion and 25 samples per input kind per cell. Host GPU 1 % before starting (the app
and another session's viewer closed first; they had it at 37 %).

| Variant | Updates/s | Stutter | Key / click / move median, ms | Viewer memory | Viewer CPU |
|---|---|---|---|---|---|
| baseline r1 / r2 | 180.1 / 180.1 | 0 / 0 % | 16.6 16.8 16.5 / 16.6 16.7 16.6 | 181-182 MB | 1.3 % |
| record r1 (discarded) / r2 | 164.1 / 180.1 | 4.7 / 0 % | 86 119 120 / 16.6 16.6 16.6 | 182-186 MB | 1.4 % |
| replay (last 30 s) r1 / r2 | 180.1 / 180.1 | 0 / 0 % | 16.5 11.1 11.0 / 16.6 11.0 11.0 | 201-203 MB | 1.3 % |
| both r1 / r2 | 179.3 / 180.1 | 0 / 0 % | 11.0 11.0 11.0 / 16.6 16.6 16.6 | 204-206 MB | 1.2 % |

- **No measurable cost** on the picture or on input: within the meter's resolution (one host refresh, 5.6 ms at 180 Hz)
  every variant equals the baseline. The viewer's own numbers agree (received = shown = 180 FPS, decode 0.22-0.26 ms,
  host processing 2.4-2.5 ms in all of them).
- record r1 is discarded by the rule of lab-craft §1: in that sample the screen meter itself only managed 165.5
  reads/s (180 in every other one) while the viewer kept receiving and showing 179.3 FPS: the host's screen reads were
  starved by something outside the stream. The same variant in round 2, and "both" (which records too) in both
  rounds, show no cost.
- Memory: the last-30-s buffer added 20-25 MB here, because this test picture (a moving bar) compresses to 8-18 MB/min.
  At his bitrate on a busy screen it holds 30-40 s of the stream: ~90-120 MB at the 179 MB/min of the first real
  recording, at most ~175 MB at a constant 35 Mb/s, capped at 320 MB (then fewer seconds are kept).
- The periodic key frame (every 10 s while recording or buffering) shows no stutter at 180 FPS.

Files the viewer wrote in this run (8, all checked then deleted):

| File | Duration | Size | Per minute | ffmpeg decode | Media Foundation |
|---|---|---|---|---|---|
| recordings (r1, both r1, r2, both r2) | 80.6-88.8 s | 27-30 MB | 18-22 MB | 0 errors | opens, AAC decodes, seeks |
| last 30 s (r1, both r1) | 38.8-39.9 s | 11.7-11.8 MB | 18 MB | 0 errors | opens, AAC decodes, seeks |
| last 30 s (r2, both r2) | 30.7-30.9 s | 4.3 MB | 8.4 MB | 0 errors | opens, AAC decodes, seeks |
| screenshots | - | PNG 1920x1080 | - | - | - |

- Disk per minute depends on what the screen does: 8-22 MB/min for this test picture, **179 MB/min** for the first real
  recording (desktop with windows moving), at most ~262 MB/min at a constant 35 Mb/s.
- A clip of the last 30 s is 30-40 s long (it starts at the newest key frame at least 30 s back); saving it takes
  100-110 ms until the app is told; stopping a recording 107-115 ms.
- A screenshot takes 107-216 ms from the command to the PNG announced (copy from the GPU, conversion, PNG on a worker
  thread); nothing changes in the stream while it runs.

## Open question for him

His machines stream HEVC and this PC has no HEVC extension: recordings don't open in Películas y TV / Reproductor
multimedia (they do in browsers and VLC). Decided (via the coordinator, his option 1): a line in Ajustes › Capturas
with a link to Microsoft's HEVC extension when Windows can't play HEVC; no re-encoding, no codec change.
