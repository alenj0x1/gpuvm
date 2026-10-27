# CPU reservation

**Hypothesis:** Reserving 100 % of 8 threads leaves the host (Moonlight, vmwp, GPU scheduling) with little headroom; a 30 % reservation with a high weight gives the same FPS and less stutter.

## Procedure

1. Apply the baseline: `Set-GpuVM -Name <vm> -Profile max-performance`
2. Measure and record with `Add-GpuVMLabResult -Lab 006 -Variant baseline ...`
3. Apply the candidate and repeat with `-Variant candidate`.
4. Close with `Close-GpuVMLab -Lab 006 -Status adopted|rejected|inconclusive -Conclusion '...'`

## Observations

