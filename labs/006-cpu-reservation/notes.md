# CPU reservation

**Hypothesis:** Reserving 100 % of 8 threads leaves the host (Moonlight, vmwp, GPU scheduling) with little headroom; a 30 % reservation with a high weight gives the same FPS and less stutter.

## Procedure

1. Apply the baseline: `Set-GpuVM -Name <vm> -Profile max-performance`
2. Measure and record with `Add-GpuVMLabResult -Lab 006 -Variant baseline ...`
3. Apply the candidate and repeat with `-Variant candidate`.
4. Close with `Close-GpuVMLab -Lab 006 -Status adopted|rejected|inconclusive -Conclusion '...'`

## Observations


- 2026-10-27: the host reports `Hypervisor scheduler type is 0x4` (root scheduler, event 2 of Microsoft-Windows-Hyper-V-Hypervisor). Microsoft documents that caps, weights and reserves only apply with the classic or core scheduler, so the 30 % vs 100 % comparison cannot show a difference. The lab now compares 8 vs 6 virtual processors. Source: https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/manage/manage-hyper-v-scheduler-types
