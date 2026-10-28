# Stream start time

**Hypothesis:** With the Hyper-V display disabled, Sunshine's per-session display configuration (ensure_only_display) only adds work: every change makes it re-test all encoders before the first frame. Disabling it (dd_configuration_option = disabled) cuts the time to the first frame.

## Procedure

1. Apply the baseline: `Set-GpuVM -Name <vm> -Profile max-performance`
2. Measure and record with `Add-GpuVMLabResult -Lab 008 -Variant baseline ...`
3. Apply the candidate and repeat with `-Variant candidate`.
4. Close with `Close-GpuVMLab -Lab 008 -Status adopted|rejected|inconclusive -Conclusion '...'`

## Observations

