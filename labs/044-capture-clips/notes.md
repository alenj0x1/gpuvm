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
