# Lab 048: lossless screen capture from a helper in the user's session

Machine: i5-12400, RTX 4060 host; test VM `agentlab` (Windows 10 Pro 22H2, 4 GB, 4 threads, GPU-P, GpuVM's virtual
display at 1920x1080@60, Sunshine 2026.914 with `capture = wgc`), Nov 18, 2026. Probe: `agentprobe` (Rust, windows
0.62, png 0.18, image-webp 0.2).

## Hypothesis

A helper started by a SYSTEM service in the signed-in user's session can take a lossless screenshot of the virtual
display in a few tens of ms with DXGI Desktop Duplication (WGC as fallback), small enough for a model at ~1280x800,
while Sunshine streams; mode changes are survivable and the secure desktop is detectable.

## Method

- Launch path: a one-shot SYSTEM task (stand-in for the service) runs `agentprobe launch`, which calls
  `WTSGetActiveConsoleSessionId` + `WTSQueryUserToken` + `CreateProcessAsUserW` (desktop `winsta0\default`).
- `run.ps1 -Stream`: scene = Explorer on C:\Windows over Notepad with a file listing; 2 rounds x {idle, Moonlight
  streaming 1080p60} x {DXGI, WGC}, 30 screenshots each (random 30-100 ms pauses). Per screenshot: newest frame ->
  CPU readback -> BGRA->RGB -> area-average scale to fit 1280x800 (1280x720 here) -> PNG (fdeflate "fast" and
  "balanced") and lossless WebP at both sizes.
- Mode change: a watcher (logs every state change and frames/s every 5 s) while the host switches the display
  1920x1080 -> 1366x768 -> 1920x1080 (1280x720 isn't offered by the virtual display).
- Secure desktop: a watcher while lab 042's `raise-prompt.ps1` opens an administrator prompt, then denies it.

## Results

**Launch from SYSTEM into the session:** works; the helper runs as `AGENTLAB\gpuvm`, medium integrity, session 1,
5 ms to create the process. Run as SYSTEM in session 0, DXGI lists the adapters but **no outputs**, and
`OpenInputDesktop` fails: capture must happen in the user's session. The guest shows three "NVIDIA GeForce RTX 4060"
adapters (GPU-P) plus Basic Render; only one has the virtual display (`\\.\DISPLAY3`); a fresh VM also had two other
displays until GpuVM configured streaming.

**DXGI Desktop Duplication fails on GpuVM's virtual display.** `DuplicateOutput` and `DuplicateOutput1` both succeed,
then every `AcquireNextFrame` returns `DXGI_ERROR_ACCESS_LOST` (0x887A0026); re-opening loops (35-41 re-opens in 10 s,
0 frames) idle and while streaming, in all 4 bench cells, and through the whole mode-change run. Creating the device
on the other two GPU-P adapters fails (E_INVALIDARG). Twice, right after a window opened, it delivered frames for a
few seconds (17.5 frames/s), then lost access again. Same family as GpuVM's note on Sunshine's `ddx` ("black until
something changes"), which is why GpuVM already defaults Sunshine to WGC. On the host (real monitor) the same code
works (first frame in 2-20 ms).

**Windows.Graphics.Capture works** (n = 60 per cell, p50 / p95 ms):

| step | idle | while streaming |
| --- | --- | --- |
| open (device + item + pool + session) | 277 | 245 |
| first frame after open | 8.8-10.1 | 8.3-20.9 |
| take newest frame (poll + GPU copy) | 0.7 / 1.0 | 0.8 / 1.2 |
| GPU -> CPU readback 1920x1080 | 7.4 / 9.9 | 6.0 / 10.5 |
| BGRA -> RGB | 3.4 / 4.0 | 3.6 / 4.5 |
| scale to 1280x720 (CPU area average) | 14.3 / 17.6 | 15.0 / 17.2 |
| PNG fast, 1920x1080 | 7.6 / 9.7 (553 KB) | 8.2 / 10.1 (554 KB) |
| PNG fast, 1280x720 | 3.9 / 5.3 (338 KB) | 4.0 / 5.3 (338 KB) |
| PNG balanced, 1280x720 | 46.1 / 50.0 (252 KB) | 49.2 / 53.5 (252 KB) |
| **lossless WebP, 1280x720** | **6.0 / 7.9 (257 KB)** | 6.5 / 7.8 (257 KB) |
| lossless WebP, 1920x1080 | 12.9 / 15.6 (377 KB) | 13.7 / 16.1 (378 KB) |

- A model-ready lossless screenshot (newest frame -> 1280x720 WebP) costs **~32 ms** in the helper, ~257 KB for this
  desktop; ~2 ms more over hvsocket (lab 047). The CPU scale is half of it; a GPU scale (or WGC at the target size)
  would remove it. Streaming at 1080p60 changes nothing measurable.
- Lossless WebP is as small as balanced PNG and 8x faster to encode. PNG fast is the fastest but 30 % bigger.
- WGC delivered 55-60 frames/s while the desktop looked still (it follows composition), so "newest frame" is always
  fresh (59/60 samples had a new frame).
- **Mode change:** no error; with `Direct3D11CaptureFramePool.Recreate` on a `ContentSize` change, frames came at
  1366x768 1.0 s and back at 1920x1080 0.55 s after the host's display call returned. Without it the frames keep the
  old size (first run).
- **Secure desktop:** `OpenInputDesktop` from the helper fails with error 5 the whole time the prompt is up and returns
  `Default` 0.8 s after the answer: that is the `secure_desktop` signal. WGC does **not** fail and keeps delivering
  ~60 frames/s of the user's desktop (stale; the prompt itself is never in them), so a frame alone can't tell; DXGI
  (when it works) fails with E_ACCESSDENIED to re-open. The helper must check the input desktop before every
  screenshot and action.
- Screenshot sample: `out/run-20261118-195558/wgc-small.png` (1280x720) and `.webp`.
- Unverified: whether Windows 10's WGC capture border shows on the guest screen during a capture (GpuVM's Sunshine
  has used WGC by default without reports of one).

## Security impact

Nothing changed in the product. The probe runs with the signed-in user's medium token (never SYSTEM in the user's
desktop); the lab used a disposable VM and removed its scheduled tasks and files.

## Conclusion

Use **WGC** as the primary (and, on GpuVM's virtual display, only) capture in the session helper, recreate the pool
on size changes, encode **lossless WebP at the model size** (~6 ms, ~250 KB), and gate every capture and action on
`OpenInputDesktop` == `Default` (report `secure_desktop` otherwise). DXGI stays a fallback for physical-display
setups only. Next: scale on the GPU to bring the full path under ~20 ms.
