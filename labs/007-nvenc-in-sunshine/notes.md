# NVENC in Sunshine

**Hypothesis:** Setting nvenc_preset=1, quarter-resolution two-pass and latency_over_power reduces encoding latency compared to the defaults. Applies to new VMs (the profile's sunshine.conf).

## Procedure

1. Apply the baseline: `Set-GpuVM -Name <vm> -Profile max-performance`
2. Measure and record with `Add-GpuVMLabResult -Lab 007 -Variant baseline ...`
3. Apply the candidate and repeat with `-Variant candidate`.
4. Close with `Close-GpuVMLab -Lab 007 -Status adopted|rejected|inconclusive -Conclusion '...'`

## Observations


- 2026-10-27: the first candidate equalled Sunshine's defaults (preset 1, quarter_res, latency_over_power), so it could not show a difference. New candidate: single pass, no VBV increase, no split encode. Source: https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html
