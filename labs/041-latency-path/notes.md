# Lab 041 notes

**Goal:** the lowest input-to-photon latency for GpuVM's streams, with smooth motion.

## Nov 17, 2026: the cause of the 5x slower streams (win-gpu, 180 FPS, V-Sync and pacing off, borderless)

Labs 020/021 that day measured both viewers at ~80 ms and 20-40 picture updates per second. Ruled out one by one (lab
021 notes): the viewer, the GDI target, Sunshine's capture mode. Research into the virtual display under GPU-P,
Sunshine/NVENC and the client found no cap in IddCx, the virtual display driver, Sunshine or the client that explains it;
win10 had given 164-173 updates/s with the same driver on Nov 8.

The cause was the host GPU, which the VM shares through GPU-P: five headless Chromes left running since the morning by
lab 040 (its `proc.kill()` ended only the launcher) took ~37 % of it. Closed (and two other GPU-using apps closed), `out/run-20261117-200713.json`:

| Variant | GPU idle / streaming % | Updates/s | Stutter % | Host ms | Key / click / move median, ms |
|---|---|---|---|---|---|
| app-closed r1 | 2.3 / 36.7 | 178.6 | 0.1 | 3.7 | 16.6 / 16.6 / 16.5 |
| app-home r1 | 37.2 / 37.8 | 171.8 | 0.4 | 4.5 | 21.9 / 16.6 / 16.8 |
| app-closed r2 | 9.7 / 36.0 | 151.5 | 6.6 | 3.9 | 16.5 / 11.1 / 11.1 |
| app-home r2 | 38.5 / 37.0 | 174.2 | 0.8 | 4.3 | 16.5 / 16.6 / 11.2 |

- Back to Nov 8's numbers (and 11 ms medians in one round): about 2-3 host refreshes from input to picture.
- GpuVM's own window on Home takes ~37 % of the GPU (the hologram): +0.6-0.8 ms of host processing and an extra host
  frame now and then. Nothing a user sees while it runs; worth removing.
- Lab 040 now ends its Chrome's whole process tree, also on errors, and sweeps leftovers first (`chrome.mjs`); the
  latency labs stop when the GPU is busy before measuring (`Assert-LatencyGpuIdle`).

## Nov 17, 2026: Sunshine settings (win-gpu, app closed, GPU idle)

`out/run-20261117-203227.json` (2 rounds, 25 samples per kind) and `out/run-20261117-205018.json` (3 rounds, 40).
The meter counts in host refreshes (5.6 ms), so medians only take 11.1 or 16.6 ms; the mean of many samples (taken
at random phases) resolves less than a refresh.

| Variant | Host processing, ms | Mean input latency, ms (95 %), run 2 | Per round |
|---|---|---|---|
| baseline (Sunshine's defaults) | 3.6-4.0 | 13.4 ± 0.3 | 13.6 / 13.3 / 13.3 |
| twopass-off (`nvenc_twopass = disabled`) | 2.4-2.9 | **11.4 ± 0.2** | 11.2 / 11.4 / 11.5 |
| minfps-20 (`minimum_fps_target = 20`) | 3.6-4.1 | 16.8 ± 0.1 | 16.7 / 16.8 / 16.8 |

- NVENC without its quarter-resolution first pass takes ~1.1 ms less from capture to packet in every round, and most
  inputs then show 2 host refreshes after the key instead of 3. Adopted for new VMs (guest/streaming.ps1) and for
  existing ones when they open (Set-SunshineVirtualDisplay, in the same restart). Its documented cost (bitrate
  overshoot on lossy networks) doesn't apply to a local virtual switch with 0 % loss.
- A lower minimum FPS (fewer re-encodes of an unchanged picture) helps nothing: rejected.
- All variants moved the GPU-drawn bar ~180 times per second with 0-0.1 % stutter.
- Found on the way: GpuVM restarted Sunshine through `/api/restart` after changing its config, which with WGC capture
  (the default; Sunshine runs from the user's logon task) leaves it stopped, so an open could fail with "Sunshine no
  responde" after the virtual display or the audio sink changed. It now restarts it as GpuVM starts it in that mode.

## Nov 17, 2026: inside GpuVM's window vs full screen (PresentMon 2.6.0, Intel, signed)

PresentMon (`--session_name` of its own, run alone after the motion measurement: alongside the GDI screen reads it
got garbage timestamps) records how the viewer's frames reach the screen. `out/run-20261117-223559.json`, 3 rounds:

| Variant | Present mode | Present to screen, mean ms |
|---|---|---|
| baseline (borderless full screen) | Hardware: Independent Flip (100 %) | 1.15-1.22 |
| windowed, viewer frame queue 3 (upstream) | Composed: Flip (100 %) | 9.5-10.0 |
| windowed, frame queue 1 (`SetMaximumFrameLatency(1)`, tried) | Composed: Flip (100 %) | 10.1-10.8 |

- Full screen goes straight to the monitor with tearing allowed (V-Sync off): ~1 ms. A picture that is not full
  screen (inside GpuVM's window) is composed by DWM: ~9 ms more, the compositor's own delay, not the viewer's queue.
  Limiting the queue changed nothing: rejected, the viewer keeps upstream's presents. The in-app view costs ~9 ms by
  nature; for games, full screen (as win-gpu is set).
- The input meter (GDI screen reads) came out worse for full screen than for windowed in one run (16.6 vs 13.4 ms):
  reading the screen with GDI may bring DWM back into an independent-flip picture. For the client side, PresentMon is
  the reference; the input meter compares variants of the same present mode.
- Same day, the hologram: at 180 FPS its WebView takes ~13 points of GPU above a still page in the preview, about
  half just to present a new frame 180 times a second (an empty canvas costs 7 points), half for the drawing. The
  machine's screen on the cube is now redrawn at 30 FPS (it drifts slowly) and the scan lines are one pattern fill:
  17.0 -> 16.4 % in an interleaved A/B. A desynchronized canvas changed nothing. The only big lever is the frame rate.
