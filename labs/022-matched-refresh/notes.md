# Matched refresh rate

**Hypothesis:** Labs 020 and 021 left trade-offs: V-Sync off for the lowest latency (with possible tearing), frame pacing only good at 60 FPS, and about 1 % stutters at 120 and 165 FPS. Part of it comes from the VM's virtual display running at a rate that doesn't match the host monitor (165 against 179.998 Hz), so updates alternate between one and two host refreshes. With the virtual display at the monitor's rate, V-Sync should cost nothing and the stutters should drop, so no use has to give anything up.

## Procedure

- The Virtual Display Driver in the VM (`C:\VirtualDisplayDriver\vdd_settings.xml`) offered 60, 90, 120, 144, 165 and 244 Hz in `<global>`; asking for 180 got 165. `run.ps1` adds `<g_refresh_rate>180</g_refresh_rate>` (backup in `vdd_settings.xml.bak-lab022`) and restarts the device, after which `1920x1080@180` applies.
- Smoothness with lab 021's bar and input latency with lab 020's squares (both scripts now take `-Custom` variants, wait for the picture before measuring and record when each session started), 2 interleaved rounds each. Sunshine's log saved at the end.
- Host monitor: 179.998 Hz (QueryDisplayConfig).

## Observations

### Run of Nov 8, 2026 (`out/run-20261108-161515`)

Smoothness (updates per second, interval sd and p99 in ms, stutters):

| Variant | Round 1 | Round 2 |
|---|---|---|
| 180 V-Sync | 168 / 1.7 / 11.3 / **0.45 %** | 173 / 2.3 / 11.1 / 0.58 % |
| 180 no V-Sync | 164 / 1.9 / 11.3 / 0.40 % | 167 / 1.8 / 11.2 / 0.84 % |
| 180 V-Sync + pacing | 169 / 2.3 / 10.8 / 0.68 % | 169 / 2.3 / 10.7 / 0.59 % |
| 165 V-Sync | *92* / 3.4 / 15.7 / 1.04 % | 160 / 2.5 / 11.5 / 0.69 % |

Input latency (ms, 80 samples per cell, both rounds):

| Variant | Key median / p95 | Click median / p95 | Move median / p95 |
|---|---|---|---|
| 180 V-Sync | 16.5 / 21.9 | 16.6 / 22.5 | 16.3 / **17.0** |
| 180 no V-Sync | 16.6 / 16.9 | 16.6 / 22.5 | 16.6 / 16.8 |
| 120 V-Sync | 16.7 / 22.5 | **22.1** / 28.0 | 16.7 / 22.5 |
| 120 no V-Sync | 16.7 / 27.7 | 16.7 / 27.8 | 16.6 / 22.1 |

- At 180 Hz the stutters fall to 0.4-0.8 % (165: 0.7-1.0 %, lab 021: about 1 %) and the gaps are steadier (sd 1.7-2.3 ms).
- At 180 Hz V-Sync costs no latency: the same medians as without it, and round 2 of 180 V-Sync measured **11 ms** on all three inputs (one host frame less than any other session; the phase between the VM's frames and the monitor lines up). At 120 Hz V-Sync still adds a frame to clicks (22.1 ms), as in lab 020.
- Frame pacing at 180 Hz is neither better nor worse.
- **Slow picture after reconnecting** (still open): 4.6-57.7 s from Moonlight's start to a moving picture. Sunshine's log shows each new session creating and tearing down the NVENC encoder 4-5 times over ~9 s, re-reading the display ("Desktop resolution") about 15 times before "Capture format" and the real encoder start; after a display mode change it also logs "Encoder reenumeration is required" (~8 s more, labs 008 and 019). The rest of the wait is not explained by the log. Also seen: `nvprefs: NVAPI_ACCESS_DENIED` on every session, "Active GPU has HAGS disabled" and the encoder created as "HEVC P1 async two-pass".

## Conclusion

Confirmed. With the virtual display at the monitor's refresh rate, V-Sync is free and the stream is the smoothest measured, so "Competitive" and "Games" become the same setting with no tearing. Adopted in the code (not yet released): `fps = 0` means the host monitor's rate, read when the VM opens; GpuVM adds that rate to the virtual display when it is missing; new VMs default to it with V-Sync on. The slow picture after reconnecting needs its own lab.
