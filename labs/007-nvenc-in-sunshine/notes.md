# NVENC in Sunshine

**Hypothesis:** Setting nvenc_preset=1, quarter-resolution two-pass and latency_over_power reduces encoding latency compared to the defaults. Applies to new VMs (the profile's sunshine.conf).

## Procedure

1. Apply the baseline: `Set-GpuVM -Name <vm> -Profile max-performance`
2. Measure and record with `Add-GpuVMLabResult -Lab 007 -Variant baseline ...`
3. Apply the candidate and repeat with `-Variant candidate`.
4. Close with `Close-GpuVMLab -Lab 007 -Status adopted|rejected|inconclusive -Conclusion '...'`

## Observations

