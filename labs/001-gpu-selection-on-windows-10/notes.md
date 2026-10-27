# GPU selection on Windows 10

**Hypothesis:** With both the RTX 4060 and the UHD 730 partitionable, Windows 10 (no -InstancePath) might assign the integrated GPU to the VM. Disabling the UHD 730 before powering on the VM guarantees it gets the 4060.

## Procedure

1. Apply the baseline: `Set-GpuVM -Name <vm> -Profile balanced`
2. Measure and record with `Add-GpuVMLabResult -Lab 001 -Variant baseline ...`
3. Apply the candidate and repeat with `-Variant candidate`.
4. Close with `Close-GpuVMLab -Lab 001 -Status adopted|rejected|inconclusive -Conclusion '...'`

## Observations

