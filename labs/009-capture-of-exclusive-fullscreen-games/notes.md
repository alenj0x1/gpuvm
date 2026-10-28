# Capture of exclusive fullscreen games

**Hypothesis:** Desktop duplication (ddx) gets no new frames from the virtual display while a game is in exclusive fullscreen, so the stream stays black. Windows.Graphics.Capture (wgc), with Sunshine running in the user's session, captures it.

## Procedure

1. Apply the baseline: `Set-GpuVM -Name <vm> -Profile max-performance`
2. Measure and record with `Add-GpuVMLabResult -Lab 009 -Variant baseline ...`
3. Apply the candidate and repeat with `-Variant candidate`.
4. Close with `Close-GpuVMLab -Lab 009 -Status adopted|rejected|inconclusive -Conclusion '...'`

## Observations

