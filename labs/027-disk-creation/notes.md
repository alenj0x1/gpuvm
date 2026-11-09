# Disk creation

**Hypothesis:** Creating a VM slows the PC because DISM unpacks the ISO at normal priority every time, and it takes long for the same reason. Applying each ISO edition once to a base disk, copying that base for every new VM, running the heavy work at low priority and mounting the disks without a drive letter makes creation faster without the PC noticing.

## Procedure

`run.ps1` (elevated, PowerShell 7) creates VMs with the module at HEAD (`old`) and with the working tree (`new-cold`: no base yet; `new-warm`: base ready), one after another with a cool-down, while `tools/host-probe/probe.ps1` times the host every 200 ms at normal priority: a CPU task that takes ~2 ms when idle, a flushed 4 KB write (saving a file) and an uncached 64 KB read (opening one). Each creation's steps are timestamped (`GpuVMProgressSink`) so the probe can be sliced per step. The last VM is booted until Windows is ready and its C: checked; with `-DiskLab`, lab 028 runs on it. Everything is removed at the end.

`copy-ab.ps1` (no elevation) compares only the copy of a large file: robocopy `/J` against GpuVM's paced copy with different settings, interleaved, with the same probe.

## Observations

### Runs of Nov 8, 2026 (Win10 22H2 es-MX ISO, balanced profile at 4 GB, Kingston NV2 1 TB)

First run of `new-cold` (DISM at idle priority with low I/O, robocopy `/J` copy, driver copied in background mode): 703 s. DISM did not show on the host (writes p95 6.9 ms), but the 12.5 GB robocopy copy froze saves (p50 **268 ms**, p95 457 ms) and the driver copy in background mode took 158 s with writes up to 968 ms.

Copy alone, 12 GB, two rounds in reverse order (`copy-ab.ps1`):

| Variant | MB/s | Save p95 | Saves > 50 ms |
|---|---|---|---|
| robocopy /J | 275-773 | 15-354 ms | 0-86 |
| paced, up to 400 MB/s | 260 | 6-8 ms | 0 |
| paced, up to 120 MB/s | 67-87 | 3-20 ms | 1-21 |
| flat 60 MB/s | 52 | 3 ms | 0-1 |

With 3 GB nothing showed (robocopy at 1 GB/s, no stalls): the NV2 has no DRAM and the harm appears once its fast cache is full, after ~10 GB written in a row. The first variant after creating the 12 GB source paid for the source still being written; the script now flushes it and waits 90 s.

Final run, with the paced copy and the driver copied at normal priority:

| Variant | Time | CPU task p95 / p99 | Save p50 / p95 / p99 | CPU tasks > 10 ms | Saves > 50 ms |
|---|---|---|---|---|---|
| idle | 60 s | 2.6 / 3.8 ms | 3.9 / 5.5 / 7.8 ms | 0 | 1 |
| old | **162 s** | **10.7 / 25.2 ms** | 3.9 / **49.4 / 97.7 ms** | **41** | **34** |
| new-cold | 346 s | 2.6 / 3.0 ms | 2.5 / 4.9 / 10.3 ms | 0 | 2 |
| new-warm | **84 s** | 2.6 / 5.3 ms | 2.2 / 9.6 / 17.1 ms | 2 | 0 |
| new-warm (driver list remembered) | **57 s** | 3.0 / 3.9 ms | 2.5 / 14.3 / 132.6 ms | 0 | 3 |

- `old` applies Windows in 104 s but its DISM takes the CPU from everything else (the CPU task 4-10x slower) and saves wait up to 100 ms: this is the PC slowing down.
- `new-cold` applies the ISO into the base in 259 s at idle priority (I/O at low priority makes Windows throttle it, about 2.5x slower than at normal), without the host noticing; the copy runs at 260 MB/s with no stalls.
- `new-warm`: 32 s of the 84 went into asking WMI for the driver's files (it walks every driver's files). The list is now remembered per device and driver version (validated paths, `gpu-driver-files.json` in the data folder): 2 s.
- The copy boots: Windows ready in 251 s, C: 128 GB (the base is 32 GB and grows to the profile's size), Windows 10 Pro.
- The base takes 12.5 GB once per ISO and edition.

## Conclusion

Adopted. Creating a VM goes from 162 s with the PC slowed down to 57-84 s without the PC noticing; the first VM of an ISO takes 346 s, also without the PC noticing. I/O priority does not reach the SSD for big copies: pacing the writes ourselves does. Background mode for GpuVM's own process made the driver copy 30x slower with no gain, so it is not used.
