# Input latency

**Hypothesis:** GpuVM opens Moonlight with settings that favor smoothness (V-Sync on, windowed). Turning off V-Sync and frame pacing, using borderless or exclusive fullscreen and streaming at the host's refresh rate lowers the time from a key press, click, mouse move or gamepad button on the host to the change in Moonlight's picture, enough for competitive games, without needing anything on the Sunshine side.

## Procedure

- `tools/latency/input-target.ps1`: a black full-screen window with four squares that switch between black and white on Scroll Lock, left click, any pointer movement and button A of any XInput pad. Inputs are polled in a tight loop (`GetAsyncKeyState`, `GetCursorPos`, `XInputGetState`) and the square is drawn at once with GDI; a bar keeps moving along the bottom so Sunshine streams real frames. `start-target.ps1 -Script input-target.ps1` starts it in the VM.
- `tools/latency/input-meter.ps1`: injects one input with `SendInput` (Scroll Lock by scan code, left button down, a 40-unit relative move alternating direction) and reads the matching square on the host screen until it flips. For the gamepad there is no injection on the host (that would need ViGEmBus on the host): it waits for a real press of A on the pad connected to the host and times from the moment XInput reports it.
- Screen reads go through GDI (`BitBlt` of one pixel); each read returns a freshly composed DWM frame, about 179 reads per second on the 180 Hz host. The time resolution is one host refresh (5.6 ms), the same for every variant. The monitor's scan-out and pixel response are not included.
- `labs/020-input-latency/run.ps1` (elevated): first the **local** reference (target on the host, no streaming: meter + target + DWM), then each variant with the target in the VM, in interleaved rounds. Each variant starts from the client settings GpuVM saved for the VM and changes only what it lists; Moonlight's arguments come from `Get-MoonlightStreamArguments`, as the app builds them. 40 samples per kind, random 150-400 ms pauses, 3 discarded samples first (the first click captures the mouse in Moonlight).

Variants: `baseline` (as GpuVM opens it today), `borderless-novsync`, `fullscreen-novsync`, `borderless-novsync-60`, `borderless-novsync-180`, `borderless-novsync-h264`, `borderless-novsync-av1`.

### What the sources say

Moonlight-qt 6.2.0 (source at tag v6.2.0):

- V-Sync off: the D3D11 renderer presents with `ALLOW_TEARING` on a flip-discard swap chain and avoids `SetMaximumFrameLatency(1)` so `Present` doesn't wait on DWM; the setting's tooltip promises "sub-frame rendering latency" at the cost of tearing ([d3d11va.cpp](https://github.com/moonlight-stream/moonlight-qt/blob/v6.2.0/app/streaming/video/ffmpeg-renderers/d3d11va.cpp), [SettingsView.qml](https://github.com/moonlight-stream/moonlight-qt/blob/v6.2.0/app/gui/SettingsView.qml)).
- Frame pacing waits on V-Sync and can queue up to 3 frames ([pacer.cpp](https://github.com/moonlight-stream/moonlight-qt/blob/v6.2.0/app/streaming/video/ffmpeg-renderers/pacer/pacer.cpp)): it adds latency by design.
- Moonlight's own tooltip says fullscreen "generally provides the best performance"; NVIDIA's [latency guide](https://www.nvidia.com/en-gb/geforce/guides/system-latency-optimization-guide/) recommends exclusive fullscreen to bypass the compositor.
- Mouse motion: Moonlight merges queued SDL motion events into one delta ([mouse.cpp](https://github.com/moonlight-stream/moonlight-qt/blob/v6.2.0/app/streaming/input/mouse.cpp)) and moonlight-common-c sends at most one motion packet per millisecond (`MOUSE_BATCHING_INTERVAL_MS 1`, [InputStream.c](https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/InputStream.c)). Relative (capture) mode is the one for games; `--absolute-mouse` is for remote desktop.
- Gamepads: with a joystick connected the event loop polls every 1 ms ([session.cpp](https://github.com/moonlight-stream/moonlight-qt/blob/v6.2.0/app/streaming/session.cpp)); controller packets are merged while queued but a button change always ends the batch. `--background-gamepad` has no latency effect.

Sunshine (v2026.914, [configuration.md](https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/docs/configuration.md)):

- `nvenc_preset` defaults to 1, already the fastest; `nvenc_latency_over_power` and `nvenc_realtime_hags` default to on. `nvenc_twopass = disabled` is faster but the docs advise against it (bitrate overshoot, packet loss). Nothing to change on the encoder side.
- `capture`: `ddx` is the supported one, `wgc` is beta; no documented latency comparison.
- Keyboard and relative mouse are injected through Sunshine's virtual HID driver when present, otherwise `SendInput`; gamepads through ViGEmBus ([troubleshooting.md](https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/docs/troubleshooting.md)).

Reference figures: NVIDIA reports 50-100 ms system latency for most players and shows aiming improving between 20 and 12 ms ([Reflex](https://www.nvidia.com/en-us/geforce/news/reflex-low-latency-platform/)); a 125 Hz mouse adds up to ~3 ms against 1000 Hz. No rigorous measurement of Moonlight/Parsec/Steam Link on a LAN was found.

## Observations

### Run of Nov 8, 2026 (win10, 1920x1080, host 1920x1080 at 179 Hz, 2 interleaved rounds)

`out/run-20261108-140651.json`. Both rounds pooled, ms. "local" = target on the host, no streaming. Baseline = GpuVM today for win10: 120 FPS, windowed, Moonlight's defaults (V-Sync on, frame pacing off), codec auto.

| Variant | Key median / p95 | Click median / p95 | Move mean / median / p95 / p99 |
|---|---|---|---|
| local | 5.6 / 6.3 | 5.6 / 6.5 | 5.6 / 5.5 / 5.9 / 11.1 |
| baseline | 16.9 / 23.0 | 22.1 / 28.1 | 20.8 / 16.7 / 23.3 / 100.2 |
| borderless-novsync | 16.6 / 22.5 | 16.7 / 27.8 | 19.5 / 16.6 / 22.4 / 94.3 |
| fullscreen-novsync | 16.6 / 33.2 | 24.7 / 33.4 | 17.6 / 16.6 / **17.0** / 46.3 |
| borderless-novsync-60 | 22.1 / 27.9 | 27.8 / 44.8 | 23.5 / 22.3 / 28.5 / 39.2 |
| borderless-novsync-180 (VM at 165) | 16.5 / 22.4 | 16.7 / 27.6 | 17.6 / 16.6 / 22.2 / 49.9 |
| borderless-novsync-h264 | 16.6 / 22.2 | 17.1 / 33.3 | 17.9 / 16.6 / 22.2 / 49.9 |
| borderless-novsync-av1 | 16.5 / 22.4 | 16.9 / 28.2 | 17.5 / 16.6 / 22.4 / 44.5 |
| local pad (real Xbox 360 pad on the host, 30 presses) | 3.8 / 6.9 | | |

- The meter's resolution is the host refresh: almost every value is a multiple of 5.55 ms (1, 3, 4 or 5 host frames). Local = one host frame, so meter + target + DWM add about 5.6 ms; streaming adds about 11 ms on top at 120 FPS or more (median 16.6 vs 5.6).
- 60 FPS costs one more host frame (+5.5 ms) on every input. Anything at 120 FPS or more is the same median; 165 FPS (the virtual display refused 180 and used 165) only trims the tail.
- The codec makes no measurable difference (decode is well under a millisecond on the RTX 4060, lab 004).
- V-Sync off with borderless removes the extra frame on clicks (22.1 → 16.7) and lowers the move tail; key and move medians are already at 3 host frames with V-Sync on.
- Exclusive fullscreen has the tightest move distribution (p95 17.0, p99 46) but clicks were slower (median 24.7) and key p95 33 in round 1; the GDI read may itself disturb an exclusive-fullscreen app, so this result is less certain.
- Clicks are consistently a little slower and more spread than keys and moves in every streamed variant; not investigated.
- **Missed key samples in round 1** (baseline 38/40, borderless-novsync 40/40, 60 FPS 40/40, 180 25/40, fullscreen 27/40) while clicks and moves in the same streams worked; in round 2 keys missed 0-3 of 40. Explained by the runs below: the meter's inputs went to whatever window was in front. Round-1 key numbers come from few samples.
- Gamepad: ViGEmBus was not installed in win10 yet, so only the local reference was measured (USB pad on the host: 3.8 ms median, under one host frame because the change is caught on the next composition).

### Diagnosis and gamepad (same day, after ViGEmBus 1.22.0 was installed in win10)

`out/diag-20261108-143726` and `-144141`, `out/run-20261108-144224.json`. The target counts what it receives (`%TEMP%\gpuvm-input-target.txt` in the VM).

- First diagnosis: `SetForegroundWindow` returned false and the elevated console stayed in front of Moonlight; the target counted **0** clicks, keys and moves, and the injected inputs landed on the host's desktop. Windows only lets the process that received the last input change the foreground window. The meter now taps Alt before `SetForegroundWindow` (`BringToFront`), never injects while Moonlight isn't in front (it stops the run instead), and the run starts minimized.
- Second diagnosis: Moonlight in front; the target counted 8/8 of each kind. The first clicks after the stream starts are not seen in time (Moonlight is capturing the mouse) and keys reach the VM only after that first click, so the discarded warm-up samples now start with clicks.
- Gamepad: a real Xbox 360 pad on the host, 30 presses per variant, through Moonlight → Sunshine → ViGEmBus's virtual Xbox 360 pad → XInput in the VM.

| Variant | Pad median / p95 | Key | Click | Move |
|---|---|---|---|---|
| baseline | 17.2 / 23.6 | 16.8 / 300 (21 misses, before the first click) | 16.8 / 28.1 | 16.6 / 22.8 |
| borderless-novsync | 16.9 / 29.0 | 16.5 / 22.3 | 16.8 / 28.0 | 16.6 / 22.2 |
| fullscreen-novsync | 16.6 / 25.2 | 16.6 / 16.9 | 16.7 / 33.2 | 16.7 / 24.9 |

- Some presses of A were not counted: after each sample the meter paused 150-400 ms, and a press during the pause was never seen. No sample was wrong (0 misses); the pause is now skipped for the pad.
- The gamepad adds the same ~11 ms over local as keys and moves (local 3.8 ms); ViGEmBus costs nothing measurable over keyboard/mouse injection.
- In this run the baseline's clicks were already at 16.8 ms: with V-Sync on, the extra frame seen on clicks in the first run (22.1) shows up in some sessions and not others. Between the three variants the medians are the same; differences are only in the tails, and they move between runs.

## Conclusion

Measured: about 16.6 ms median from a key, click, mouse move or gamepad button on the host to the change in Moonlight's picture at 120 FPS or more (5.6 ms without streaming, so the stream adds about 11 ms); 60 FPS adds one more host frame. Codec and display mode make no difference to the median. At 120 FPS V-Sync sometimes adds a frame to clicks; lab 022 removed that trade-off by running the VM's display at the monitor's refresh rate, where V-Sync costs nothing. Adopted with lab 022: per-machine uses (Games, Movies and video, Work) and V-Sync, frame pacing and mouse settings.
