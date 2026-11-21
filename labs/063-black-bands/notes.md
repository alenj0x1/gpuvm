# Lab 063: the black bands, found and fixed (Windows hands the capture a frame it hasn't finished drawing)

The person's report (2026-11-21): black bands over the picture of any machine (agent copies and ordinary machines,
with games, programs, anything). Lab 057 had halved them (wait for each copy before releasing the WGC frame) and
blamed "frames Windows was still drawing" without proving it; a video playing in the machine made them more common.

Machine: `agent-tpl-85fbb0` (Windows 10 19045, 4 vCPU, 4 GB, RTX 4060 partition, GpuVM's virtual display at
1920x1080@180), used while the person's own viewer was open, with their OK.

## 1. Instruments (all in this folder)

| tool | what it does |
| --- | --- |
| `probe\` (`wgc-race.exe`, Rust) | captures the streamed display with WGC as the signed-in user, like Sunshine's helper. Modes: hold each frame and copy it twice (did it change after Windows handed it over?); `fast2`: copy inside FrameArrived, wait for the copy, release (the helper's exact pattern) at ~175 fps, read 54 rows per frame on another thread, count lab 057's black-for-one-frame frames and frames with transparent pixels; per-frame variants in turns (`0,fix,1000`: copy at once, the fix, spin 1 ms first); GPU priority like the helper (REALTIME, else HIGH, thread priority 7); cursor capture; GPU load (copies on another device), CPU load (spinning threads), `loadonly` for the host |
| `race.ps1` | runs the probe in the machine as its user (scheduled task) with a load: `label`, `video`, `labelvideo`, `churn` (a window opens every 150 ms, 6 at most), `videochurn`; `-ProbeFirst` starts it before the load |
| `helper-verify.patch` | lab-only instrumentation for the real helper (`sunshine_wgc_capture.exe`): after each copy into Sunshine's shared texture, reads 54 rows of it and of the WGC frame (still held), counts black-for-one-frame frames, frames with alpha 0, and frames whose source changed after the copy (`src_diff`); dumps the first 6 whole. On with `tools\gpuvm-lab063.txt` |
| `helper-swap.ps1` | puts a helper build in a running machine without dropping the viewer; `-Verify`, `-CheckOff` (the fix's off switch), `-Restore` |
| `helper-log.ps1`, `unfinished.ps1` | the helper's lab063 lines and dumps (as PNG); the fix's counters |
| `stream.ps1` | what the person sees: opens GpuVM's viewer with the labs' pipe, records the stream through it while `race.ps1` runs, counts the glitches in the recording (`..\057-capture-broker\glitches.py`) and reads the helper's counters |
| `ab.ps1` | rounds of fix on / fix off (same build, the off flag), each a `stream.ps1` run, one line per run in `out\ab.jsonl` |

## 2. What the bands are

Frames from lab 057's recordings (`out\l057\`): black areas shaped exactly like **what changed** on screen (the clock
window, the video), with stair-step (GPU tile) and diagonal (triangle) edges, the rest of the desktop intact; some
are the whole screen black. That is Windows' desktop composition caught half way: it redraws only what changed in
the same buffer, clearing it first.

The helper's own dumps (`out\r7-helper\`): the missing parts are **alpha 0** (13-60 % of the frame), while a
finished desktop frame is 100 % opaque. The encoder ignores alpha, so they come out black.

## 3. Where they are born

| measurement | result |
| --- | --- |
| host reference (probe on the PC, no GPU-P) | 0 of 261 frames changed after hand-over |
| probe, hold 20 ms, copy at once vs 20 ms later, video load | 0/852, 0/1170 (none changed while held) |
| probe with the helper's settings (pool 1, HIGH + thread 7) | 0/1187 |
| probe at full rate, helper's exact pattern (7.5k frames) | 0 glitches |
| **helper verification** at the same time as the probe (r7) | **6 glitches, 6 frames whose WGC buffer changed after the copy** (probe: 0) |
| stream + helper + probe, video + windows opening (s1) | stream **36** glitches/min, helper **38** (src_diff 36, alpha0 39), probe 56 |

So the black bands in the stream are the frames the helper copied while Windows was still drawing them (stream ≈
helper's count), and the WGC buffer keeps changing after the copy. The rate depends on the moment, not on one load:
36-57/min in s1, 0-5/min in the identical s3; GPU load in the machine (copies, up to 100 fps capture), GPU load on
the PC (36-100 %), CPU load in the machine (4 spinning threads) and cursor capture alone didn't bring it back. Opening
windows (Edge, Paint, the clock appearing) is when it shows most.

Why the race exists isn't visible from inside the machine: on GPU-P, FrameArrived can come before Windows' drawing
of that frame has finished on the GPU, and nothing in WGC lets a consumer wait for it (no fence, no keyed mutex on
the frame).

## 4. The fix (gpuvm-sunshine, helper)

`copy_complete_frame`: after each copy, the frame also goes into a texture with mips (one extra mip chain on the GPU)
and the last mip (one texel per 32x32 block) is read back (~2 KB). Blocks with alpha < 250 where the previous frame
was opaque mean Windows hasn't finished it: the frame is still held, so the helper waits 0.5 ms and copies it again,
until it is finished or 25 ms pass; then it is taken as it is and becomes the reference (content that really is
transparent costs one wait, not one per frame). `tools\gpuvm-frame-check-off.txt` turns it off.

| run | result |
| --- | --- |
| f1: fixed helper + verification, probe without fix at the same time, video + windows 90 s | fix caught 6: **5 finished after 0.7-1.0 ms** (one more copy), 1 still transparent after 25 ms (Edge's window opening: what Windows really drew, taken as is); helper output **0 glitches, src_diff 0** in 16k frames; the probe without fix saw 4 |
| copy wait per frame (15 s averages) | before 260-320 µs, with the fix 260-305 µs: no measurable cost; capture 171-179 fps |

## 5. End to end (ab.ps1, stream.ps1)

Black flashes counted in the stream recording (60-90 s each, video + windows opening), the helper's own counters:

| build / arm | stream (per run) | helper |
| --- | --- | --- |
| lab build, fix off (`gpuvm-frame-check-off.txt`) | 18, 0, 8, 0 | handed Sunshine 2, 10, 1 half-drawn frames |
| lab build, fix on | 0, 0 (one run lost to a PowerShell Direct error) | 0 half-drawn frames handed over; caught 2 |
| **installed build (fork be3982bb), fix on** | 2, 1, 1, 1 | caught **341, 645, 26, 111** unfinished frames and handed them over finished |
| installed build, fix off | 14, 1 | — |

The flashes left with the fix are not capture: an app's window that really is black for a moment while it opens
(Edge going full screen in kiosk mode, a new window before its first paint; `out\v-glitch\`), each matching one frame
the check "took as it was" after 25 ms (it didn't change afterwards). A physical monitor shows those too.

**What makes it worse: the GPU of the PC busy with another app's drawing.** In the runs right after installing, the
GpuVM app was open on the PC animating its home page (WebView2 at 26 % of the GPU with no stream): the probe without
the fix saw 50-120 unfinished frames a minute (copy waits of 6-7 ms instead of 0.4), the fixed helper caught them
all. GPU copies on the PC (36-100 %), on the machine or CPU load didn't reproduce it; drawing and presenting did.
Games on the PC, a browser with video, or GpuVM's own animations next to the viewer are the realistic triggers.

## 6. Shipped

- gpuvm-sunshine `be3982bb` (helper: `copy_complete_frame`, README en/es), published into `sunshine\` (helper
  `2F3958F0C999`), app built and installed. Opening a machine syncs it (`Sync-GuestSunshineFork`); the app layered
  it onto `agent-tpl` by itself right after the install (~2 min). `normal-tpl` still had the old helper when the lab
  ended: the app's hourly template check brings it.
- `tools/latency/common.ps1`: `Start-LatencyViewer -Quiet` (the viewer's console log drained instead of flooding the
  lab's output).

## Open

- The guest agent's own WGC capture (screenshots for AI agents, `guest/agent/src/capture.rs`) copies frames at
  arrival the same way and can get a half-drawn screen; it isn't checked yet.

## Lessons

- Look at the bad frames' alpha: the missing parts of a half-drawn desktop are transparent, which is both the proof
  and the cheapest detector.
- A probe that reproduces the consumer "exactly" can still miss a race the real consumer hits; instrument the real
  one (here: a lab build of the helper swapped in without dropping the viewer) and measure both at the same time.
- With a rate that swings 0-57/min from one identical run to the next, a fix is judged by its own counter (what it
  caught and how it ended) next to the stream, not by one stream count.
