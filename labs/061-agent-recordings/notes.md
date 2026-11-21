# Lab 061: lighter recordings of agents' work

GpuVM records a machine for as long as an agent holds it (`app/src-tauri/src/agent.rs`). The viewer wrote the stream
as it came: 180 fps HEVC at ~16-21 Mb/s. Lab 057's two agent sessions were 4.3 GB (35.6 min) and 6.4 GB (39.8 min):
up to **160 MB per minute, ~9.6 GB per hour**. Goal: at least 4x smaller per hour, the live picture exactly as
before, files Windows' own player opens.

**Result:** the viewer re-encodes agent recordings while it records (GPU decode, one frame every 1/30 s, Windows'
H.264 encoder at constant quality 60). Same content: **160 → 4.6 MB/min** (cutA) and **162 → 15.3 MB/min** (cutB):
**10-35x smaller** (~16x averaged). CPU ~0.4 of one core at below-normal priority, text sharp, files open in Media
Foundation. The live stream and the person's own recordings are untouched.

## Method

- Content: two 2-minute cuts of lab 057's real agent recordings (read-only; Paint being driven by an agent, menus
  opening, strokes drawn), the stream exactly as the viewer received it: cutA at 15:00 of the 10:56 file, cutB at
  20:00 of the 11:32 file. Both 1920x1080 HEVC at 180 fps, 160.3 and 162.5 MB/min as recorded today.
- Instrument: `tools/rectest.cpp` builds the viewer's own code (`transcoder.cpp`, `recordfile.cpp`, `mp4writer.cpp`
  from the `gpuvm-viewer` branch `feat/light-recordings`) and feeds the stream frame by frame on its own clock,
  `--realtime` at the stream's pace. It reports this process's CPU time (`GetProcessTimes`), the worst time one frame
  held the recorder thread, and writes the MP4. Lab 044's `mfprobe` opens each file as Windows' players do.
- `run.py` (sizes, CPU, decode-only share), `ssim_ref.py` and `quality.py` (rate control), 2 interleaved rounds.
  Raw rows: `out/results.jsonl`, `out/quality.jsonl` (git-ignored).
- The PC was shared: the coordinator's VM streamed and other sessions compiled. GPU before each run is in the rows
  (decoder 0-86 %). CPU is per process, so it moves less with load than wall time; between rounds the same variant
  differed by up to 0.1 core.

## Options considered

| Option | Verdict |
|---|---|
| Hidden viewer opened at 30 fps / low bitrate | Rejected. Sunshine fixes rate and bitrate when the session starts; when the person opens the machine, the same viewer is revealed, so they'd watch 30 fps, or the session would restart (black, a cut file, Sunshine's first-session encoder tests). Does nothing when the person's viewer is the one recording. |
| Lower rate only while nobody watches, raised on reveal | Same restart problem; changes what the person sees. |
| Re-encode finished files in the background | Needs the full 7-10 GB/h on disk first and written twice; the viewer's FFmpeg has decoders only (`--disable-all`, no demuxer/encoder), so it would need our own MP4 reader. |
| Keep every Nth frame of the stream | Not valid: P-frames reference the previous frame. |
| **Re-encode while recording (chosen)** | A second decoder on the recorder thread (the renderer's is not touched), only kept frames leave the GPU, Windows' H.264 MFT encodes them. No big intermediate file, file closes when the agent lets go. |
| GPU encoder (NVENC MFT) | Not used: GPU-P shares NVENC with the machines' own streams; a recording must not take from them. The CPU encoder is synchronous and simpler too. |

## Numbers

Sizes and CPU (`run.py`, VBR by mean bitrate; medians of 2 rounds):

| Variant | MB/min cutA, cutB | CPU s per video s | SSIM vs stream* |
|---|---|---|---|
| as recorded today | 160.3, 162.5 | 0 | 1 |
| 30 fps, 1 Mb/s | 7.3, 7.5 | 0.55 | 0.981, 0.825 |
| 30 fps, 2 Mb/s | 14.1, 14.0 | 0.58 | 0.983, 0.886 |
| 30 fps, 3 Mb/s | 16.0, 20.6 | 0.54 | 0.983, 0.889 |
| 15 fps, 2 Mb/s | 12.1, 14.0 | 0.31 | 0.983, 0.888 |
| decode only (1 fps encoded) | - | **0.05** | - |

\* Against the stream resampled to 30 fps by ffmpeg: see "Instrument" below; this column mostly measures frame picking.

- The GPU decoder isn't the cost: 0.05 core, and it decoded ~1,500 fps here (as fast as possible, with other
  viewers on it), so the stream's 180 fps is ~12 % of it. Windows' encoder is ~90 % of the CPU.
- `CODECAPI_AVEncCommonQualityVsSpeed` = 0 gave byte-identical files: Windows' encoder ignores it (removed).

Rate control (`quality.py`), SSIM against the same recorder at 40 Mb/s (same frames kept), round 1:

| Variant | MB/min cutA, cutB | CPU | mean SSIM A, B | worst 1 % A, B | frames < 0.95 A, B |
|---|---|---|---|---|---|
| VBR 2 Mb/s | 14.1, 14.0 | 0.55 | 0.9994, 0.9806 | 0.993, **0.894** | 0, **562** |
| VBR 3 Mb/s | 15.7, 20.6 | 0.55 | 0.9998, 0.9911 | 0.994, 0.925 | 0, 133 |
| quality 50 | 3.3, 10.9 | 0.47 | 0.988, 0.987 | 0.979, 0.980 | 0, 0 |
| **quality 60** | **4.6, 15.3** | 0.46 | 0.992, 0.991 | 0.986, 0.986 | 0, 0 |
| quality 70 | 6.2, 21.4 | 0.49 | 0.995, 0.995 | 0.992, 0.992 | 0, 0 |
| quality 80 | 7.7, 27.4 | 0.48 | 0.996, 0.996 | 0.993, 0.993 | 0, 0 |

- With a mean bitrate the encoder spreads its budget: when Paint's File menu opened (cutB frame 1579) the menu's text
  was a smear for about a second (SSIM 0.75; `out/cmpB-1579.png`). Constant quality spends what the change needs and
  almost nothing on a still desktop: cutA (mostly still) fell to 4.6 MB/min, cutB (strokes being drawn the whole time)
  15.3 MB/min, and no frame of either went under 0.95.
- Quality 50 left small specks next to the menu text; 60 looked like the reference (`out/cmp-menu.png`: reference,
  q50, q60). Chosen: **quality 60**.
- The chosen setting at the stream's own pace (`--realtime`, final code): cutA 10.1 MB in 127 s (**4.6 MB/min**, 35x),
  cutB 34.1 MB (**16.0 MB/min**, 10x); **0.39-0.40 core**; wall time = video time (it keeps up); worst frame held the
  recorder 65-91 ms (the recorder has a 256 MB queue: seconds of stream); `mfprobe`: H.264, decodable, all samples
  read, seek works. Per hour of agent work: **~0.3-1 GB instead of ~9.6 GB**.
- 15 fps halves the CPU (0.31 vs 0.58) for ~10 % less size; kept 30 fps so the pointer and menus stay fluid. If the CPU
  matters more later, `Transcoder::Settings::fps` is the knob.

## Instrument

- Comparing a 30 fps file with the 180 fps stream through ffmpeg's `fps` filter picks a neighbouring frame now and
  then. cutB is a Paint window with strokes drawn and lab 057's single-frame glitches in the stream, so whole frames
  differed and SSIM read 0.83-0.89 for frame picking alone. The fair reference is the same recorder at 40 Mb/s: same
  frames kept, near lossless (its own score against the resampled stream: 0.983 cutA, 0.891 cutB, the floor of the
  first method). Folded into lab-craft.
- The first version kept a frame "on time" after a late one, so two kept frames could be 5 ms apart (ffmpeg warned
  of equal timestamps). Fixed: kept frames are never closer than half an interval (min gap now 20-24 ms).

## What changed

- Viewer (`gpuvm-viewer`, branch `feat/light-recordings`): `app/gpuvm/transcoder.*` (new); `capture.cpp` records
  light when the app's `record` command says `light` (decoder and encoder open on the recorder thread, below-normal
  priority; a stream that's 10-bit or 4:4:4, or a failure to open either, records the stream as before and logs
  why); `session.cpp` passes `light`; `app.pro`.
- App: `agent.rs` asks for `{"type":"record","on":true,"light":true}` (`record_agent_work`, with a test). The
  person's own recordings (their key or panel) keep the stream as it comes.

## How to run

```
pwsh -File labs/061-agent-recordings/tools/build.ps1          # rectest from the viewer's source (-Viewer <tree>)
pwsh -File labs/044-capture-clips/tools/build.ps1 -Viewer <tree>   # mfprobe
python labs/061-agent-recordings/run.py --source "<recording.mp4>@900" --source "<other.mp4>@1200"
python labs/061-agent-recordings/ssim_ref.py
python labs/061-agent-recordings/quality.py --rounds 2
```

## Not verified here

- A live agent session with the new viewer (the GPU belongs to the coordinator's machine): the coordinator checks
  that an agent recording comes out light (the viewer's log line `GpuVM capture: light 30fps quality 60, GPU decode:
  ...`) and the live picture is unchanged.
- HEVC 10-bit / HDR or 4:4:4 streams fall back to the stream as it comes (by design; not exercised).
