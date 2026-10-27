# Moonlight latency

**Hypothesis:** Turning off V-Sync in Moonlight lowers total latency by about one frame (~16 ms at 60 FPS) without visible stutter. The performance overlay is used to measure.

## Procedure

1. Apply the baseline: `Set-GpuVM -Name <vm> -Profile max-performance`
2. Measure and record with `Add-GpuVMLabResult -Lab 004 -Variant baseline ...`
3. Apply the candidate and repeat with `-Variant candidate`.
4. Close with `Close-GpuVMLab -Lab 004 -Status adopted|rejected|inconclusive -Conclusion '...'`

## Observations

