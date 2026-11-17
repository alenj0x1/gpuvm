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
