# Lab 044: screenshots, recordings and the last 30 s

The viewer saves the machine's picture without re-encoding it: screenshots are the decoded frame as PNG, recordings
and clips are the stream's own H.264/HEVC/AV1 written into MP4 by our own writer (`gpuvm-viewer`
`app/gpuvm/mp4writer.cpp`), with the sound as AAC through Windows' encoder. This lab proves the files and measures what
it costs a live stream.

| Part | Script | What it shows |
|---|---|---|
| 1. Files | `files.ps1` | The writer on its own: test streams shaped like Sunshine's (no B-frames, a key frame every 10 s, Opus in 5 ms packets) in each case the viewer meets (H.264, HEVC, AV1, HEVC 10-bit HDR, starting mid-stream, lost frames, no sound). Every file is decoded fully by ffmpeg and opened by Media Foundation (what Windows' own players use): duration, codecs, decodable, seeking. |
| 2. Sync | `sync.ps1` | How far the sound lands from its true time through the audio path (Opus decode + AAC), with a track that beeps at every whole second. |
| 3. Live | `run.ps1` | With a real stream (viewer driven through its pipe like the app): updates/s and stutter of a GPU-drawn bar, the viewer's FPS/decode/host numbers, key/click/move latency, the viewer's CPU and memory, for baseline / recording / last-30-s buffer / both, in interleaved rounds; then the files (MB per minute, duration, playable) and the time a screenshot takes. |

## How to run

```
pwsh -File labs/044-capture-clips/tools/build.ps1           # mp4test (the viewer's writer) and mfprobe, into out\bin
pwsh -File labs/044-capture-clips/files.ps1                 # part 1 (needs ffmpeg on PATH)
pwsh -File labs/044-capture-clips/sync.ps1                  # part 2
pwsh -File labs/044-capture-clips/run.ps1 -Name win-gpu     # part 3, elevated; takes C:\GpuVM\.lab-lock
```

Results and decisions are in `notes.md`.
