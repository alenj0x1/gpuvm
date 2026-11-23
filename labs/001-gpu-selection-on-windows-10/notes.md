# GPU selection on Windows 10

**Hypothesis:** With both the RTX 4060 and the UHD 730 partitionable, Windows 10 (no -InstancePath) might assign the integrated GPU to the VM. Disabling the UHD 730 before powering on the VM guarantees it gets the 4060.

## Procedure

1. Apply the baseline: `Set-GpuVM -Name <vm> -Profile balanced`
2. Measure and record with `Add-GpuVMLabResult -Lab 001 -Variant baseline ...`
3. Apply the candidate and repeat with `-Variant candidate`.
4. Close with `Close-GpuVMLab -Lab 001 -Status adopted|rejected|inconclusive -Conclusion '...'`

## Observations

2026-11-22, RTX 4060 + UHD 730, both partitionable (32 partitions each), checked inside the guest (`Get-PnpDevice -Class Display -PresentOnly`):

- Alone, a machine got the RTX 4060 on 3 of 3 starts.
- With another machine already on the RTX 4060, the next one got the UHD 730 on 6 of 6 starts (code 10, Sunshine: "Failed to locate an output device", the viewer stuck at "Connecting the picture").
- Windows gives a starting machine the GPU with the fewest running GPU-P machines; a tie goes to the first GPU listed by `Get-VMPartitionableGpu`.
- `HostResource` on `Msvm_GpuPartitionSettingData` is accepted (`ModifyResourceSettings` returns 0) but not kept on Windows 10.
- Starting an empty machine (no disk, 64 MB, a GPU-P adapter) just before evens the count: the machine got the RTX 4060 on 6 of 6 starts with it. Adopted in `Invoke-WithGpuChoice` (Gpu.ps1), called by the module's `Start-VM`.
- Unrelated: a machine turned off hard (`Stop-VM -TurnOff`) and started again at once sometimes gives no heartbeat for minutes (2 of 4 without the empty machine, too).
