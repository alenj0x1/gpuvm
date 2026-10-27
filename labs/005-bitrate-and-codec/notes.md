# Bitrate and codec

**Hypothesis:** Host-VM traffic never reaches the physical network: raising to 60 Mbps and using HEVC improves sharpness without adding encode/decode latency.

## Procedure

1. Apply the baseline: `Set-GpuVM -Name <vm> -Profile max-performance`
2. Measure and record with `Add-GpuVMLabResult -Lab 005 -Variant baseline ...`
3. Apply the candidate and repeat with `-Variant candidate`.
4. Close with `Close-GpuVMLab -Lab 005 -Status adopted|rejected|inconclusive -Conclusion '...'`

## Observations

