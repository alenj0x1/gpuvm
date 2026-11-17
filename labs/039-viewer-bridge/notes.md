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
