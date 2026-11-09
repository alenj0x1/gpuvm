# Fixed vs dynamic disk

**Hypothesis:** A fixed VHDX makes the VM's disk faster than a dynamic one, which would justify the `max-performance` profile writing its whole 96 GB disk at creation.

## Procedure

`run.ps1` (elevated) attaches to a running VM, per round, a new 8 GB fixed disk and a new 8 GB dynamic disk (SCSI, like the system disk), formats each inside and runs from inside the VM, without Windows' file cache: writing a 4 GB file to the empty disk (a dynamic disk grows here, as when installing a game), writing it again, reading it, and 4 KB random reads and writes one at a time for 15 s. Two rounds, the order reversed in the second. Run by lab 027 with `-DiskLab` on its last VM.

## Observations

### Runs of Nov 8, 2026 (Kingston NV2 1 TB, Windows 10 guest)

| Round | Disk | Fill MB/s | Rewrite MB/s | Read MB/s | 4K read p50 | 4K write p50 |
|---|---|---|---|---|---|---|
| 1 | Fixed | 267 | 399 | 1379 | 0.18 ms | 0.10 ms |
| 1 | Dynamic | 1214 | 1788 | 1866 | 0.17 ms | 0.10 ms |
| 2 | Dynamic | 1311 | 1477 | 1732 | 0.16 ms | 0.10 ms |
| 2 | Fixed | 1279 | 189 | 1984 | 0.16 ms | 0.10 ms |

- The dynamic disk is not slower when it grows (fill 1214-1311 MB/s) nor afterwards. Random 4 KB latency is the same.
- The fixed disk's low figures come right after Hyper-V wrote its 8 GB of zeros: they fill the SSD's fast cache, and the next writes pay for it.

## Conclusion

On this PC a fixed disk brings nothing, and creating it costs minutes of a saturated SSD (and the host's responsiveness with it). `max-performance` now uses a dynamic disk. `Fixed` stays available in custom profiles.
