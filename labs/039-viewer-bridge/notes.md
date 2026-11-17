# GpuVM viewer: private pipe and first launch

**Hypothesis:** GpuVM's own viewer (fork of moonlight-qt 6.2.0, repo `gpuvm-viewer`, branch `gpuvm`) can be driven by
the GpuVM app over a private pipe without showing any Moonlight window, and reports its progress and failures there
quickly enough for the app to show them.

## Procedure

- `bridge-smoke.ps1`: plays the app's side without a VM. Creates `\\.\pipe\gpuvm-viewer-<32 hex>` for the current
  user only, starts `viewer\GpuVMViewer.exe stream <address> Desktop --gpuvm-pipe ... --gpuvm-token-env GPUVM_VIEWER_TOKEN`
  with a 64-hex token in the environment, checks the `hello` (token and PID) and prints every message with the time
  since launch until the viewer exits.
- Build: Qt 6.12.0 (msvc2022_64, installed with aqtinstall at the commit upstream's CI pins), VS 2022 Build Tools
  14.44, upstream's prebuilt deps (moonlight-qt-deps v19), `gpuvm\build.cmd Release`.

## Observations

### Nov 16, 2026 (no VM, address 127.0.0.1 with no Sunshine)

- Connected and identified 156 ms after launch; token and PID matched.
- No Qt window was shown at any point.
- `{"type":"error","message":"Failed to connect to 127.0.0.1"}` arrived at 30.6 s (Moonlight's own connection timeout),
  then the viewer exited with code 1.
- Upstream checks moonlight-stream.org for Moonlight updates and downloads gamepad mappings at every start: the update
  check is removed in the fork (GpuVM updates the viewer); the gamepad mappings download stays (it improves gamepad
  support; a public file, nothing about the user is sent).

## Pending

- Same run against a real VM: first frame time vs Moonlight (labs 019 and 023), side panel open/close, latency with
  the panel closed (lab 020) and smoothness (lab 021), to confirm the fork adds nothing while the panel is hidden.

### Nov 16, 2026 (win-gpu, full screen machine, installed builds 6-9, filmed with `screen.ps1` + `montage.ps1`)

- Build 6: one zoom only (the hologram used to move twice because the machine changed state right before the zoom);
  the viewer window flashed over the app with its border for ~100 ms when created.
- Build 7: created hidden and shown by SDL "without activation": it still came to the front, black, before the zoom.
- Build 8/9: shown natively below the app (SetWindowPos with SWP_SHOWWINDOW | SWP_NOACTIVATE; SDL hears WM_SHOWWINDOW
  and creates the decoder). Full open: nothing shows over the app, single zoom, picture at 14.7 s from the click (VM
  already on); one ~60 ms frame of the picture inside the app before it goes full screen. Ctrl+Alt+Shift+H: zoom out to
  Home in ~1.2 s; Open again: zoom in and picture in 0.7 s (session kept connected).
- A viewer killed from outside left the app showing a dark live screen on the next Open; build 9 falls back to a full
  open.
- Build 10: full screen is set before the window comes out from behind the app: zoom, ~0.3 s of the dark stage, then the picture straight in full screen (15.6 s from the click); no frame inside the app.

### Nov 17, 2026 (after the code and security reviews; installed silently with `install-build.ps1`, driven with `screen.ps1`)

- The viewer now runs at Low integrity. First run: every connection failed with "Failed to import private key"
  (NTE_PERM): Qt's Schannel backend imports the client key into the user's key store, which Low can't write. GpuVM
  mode now uses Qt's OpenSSL backend (key in memory, `tls\qopensslbackend.dll` shipped). After that: full open of a
  running win-gpu, picture full screen at ~22 s from the click (machine already on); embedding inside the app works at
  Low (owner window, placement, reveal).
- Return to a connected machine from Home: ~0.8 s, no steps (the viewer is asked first). Home from the panel: ~1.2 s.
- The cube flies from Home to its place on the machine page in ~0.5 s.
- Panel: Ctrl+Alt+Shift+G and H did nothing while the panel had the focus (only the viewer listened): the panel
  handles them too. With the panel focused over a full-screen picture, Windows showed the taskbar over the stream: the
  panel is marked full screen for the taskbar (ITaskbarList2::MarkFullscreenWindow) while the picture is.
- Weather with the real network: search, temperature and forgetting the city on removal all work under the new CSP.
- Widening the panel left the third column empty for a layout arranged in two: it now fills once. Lab 040 caught the
  clock's "10:01 AM" going past a one-column widget (passed earlier at "8:13"); the time now shrinks to fit. Lab 040:
  sizes 440/440, drags 140/140.
- Open: after many installs that killed the viewer mid-stream, win-gpu's Sunshine stopped sending video ("No video
  traffic was ever received", UDP port test OK). Not reproduced on a fresh host session yet.
