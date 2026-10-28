# Moonlight latency

**Hypothesis:** Turning off V-Sync in Moonlight lowers total latency by about one frame (~16 ms at 60 FPS) without visible stutter. The performance overlay is used to measure.

## Procedure

1. Apply the baseline: `Set-GpuVM -Name <vm> -Profile max-performance`
2. Measure and record with `Add-GpuVMLabResult -Lab 004 -Variant baseline ...`
3. Apply the candidate and repeat with `-Variant candidate`.
4. Close with `Close-GpuVMLab -Lab 004 -Status adopted|rejected|inconclusive -Conclusion '...'`

## Observations


- 2026-10-27: end-to-end meter works once Moonlight has keyboard focus. At 60 FPS, V-Sync off lowers the median from 38.9 to 33.8 ms (about 5 ms, less than one frame) and halves the p95. The p95 and missed samples come partly from the meter (single pixel read through GetPixel). 120/144 FPS: the stream stayed black because the refresh change happened while the previous Sunshine session was open; the tools now close it between variants (pending re-run).
