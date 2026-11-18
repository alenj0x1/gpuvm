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
