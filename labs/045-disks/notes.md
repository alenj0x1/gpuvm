# Disks: restore points, lighter templates, export/import

**Hypotheses:**
1. Hyper-V can take Standard checkpoints of a GPU-P VM while it is off. If it can't, GpuVM can build its own restore points with differencing disks. Creating and going back would take about a second, deleting a point would merge it, and the VM's disk path would never change.
2. A template or export can drop the space of files deleted inside the guest with an offline TRIM of the copy before `Optimize-VHD`, without touching the VM's own disk.
3. A whole machine fits in one file (compacted disk plus a manifest without secrets) and imports back verified by SHA-256.

Scripts (elevated PowerShell 7, each one cleans up after itself). They only use throwaway VMs built on `C:\GpuVM\.bases\<key>\base.vhdx` and never boot them, so they never touch the person's VMs or the GPU. Anything that moves GBs on C: takes the shared `C:\GpuVM\.lab-lock` (`lock.ps1`).

| Script | What it does |
|---|---|
| `checkpoint-probe.ps1` | `Checkpoint-VM` on a VM with a GPU partition adapter, off, with CheckpointType Disabled and then Standard |
| `points-offline.ps1` | GpuVM's restore points end to end. A marker file in the mounted guest is checked after each step (create, go back, go back while keeping the present, delete by merging point into point and the top disk into a point, branch rule, rename), along with apps state and the GPU adapter |
| `compact.ps1` | Convert-VHD of a guest disk where `-WasteGB` was written and deleted, without and with compaction of the copy, in interleaved rounds |
| `transfer-offline.ps1` | Export-GpuVM per compression, then Import-GpuVM (taken name, fingerprint, content, new Sunshine identity and web login, password, tampered file refused) |

## Observations (2026-11-18, Kingston NV2 1 TB, Windows 10 22H2 base)

### Checkpoints with GPU-P
`Checkpoint-VM` fails on an off VM with a GPU partition adapter, with CheckpointType Disabled and with Standard alike: *"The operation cannot be performed on virtual machine ... because it is assigned one or more GPU partitions."* GpuVM's own points are therefore the only option.

### GpuVM restore points (26 of 26 checks)
| Step | Time |
|---|---|
| Create a point (rename the disk + new differencing disk + re-attach) | 1.2-1.3 s |
| Go back | 1.1-1.2 s |
| Delete a point whose child is another point, with 4 GB written after it (merge + reparent the VM's disk) | 4.7 s |
| Rename a VM with points (the chain is repointed) | 0.9 s |

- Content is exactly the point's in every case (A, B, D, E markers).
- `installedApps` goes back with the disk.
- The GPU-P adapter survives.
- A point two others sit on can't be deleted.
- Deleting every point leaves the VM's disk as a direct child of its original parent, with the latest content.

### Lighter copies (8 GB written and deleted in the guest, 2 GB kept, two rounds)
| Variant | Size | Added time |
|---|---|---|
| Convert-VHD only (what templates did) | 19.25 GB | — |
| + read-only mount, `Optimize-VHD -Mode Full` | 19.25 GB | 1.3 s |
| + writable mount, `Optimize-Volume -ReTrim`, `Optimize-VHD -Mode Quick` (or Full) | 19.19 GB | 4-9 s |
| **+ read-only mount, `Optimize-VHD -Mode Retrim`, dismount, `-Mode Quick` (shipped)** | **11.29 GB** | **3.3-18.6 s** |

- The 8 GB come back whole (11.29 = 9.25 base + 2 kept), and the guest's file system is never mounted for writing.
- On an empty disk created by `New-VHD`, `Optimize-Volume -ReTrim` + Quick did work (4.1 → 0.19 GB). On a `Convert-VHD` output it reports 20 GB trimmed yet nothing is given back. Only `Optimize-VHD -Mode Retrim` on a read-only mount does.
- Convert-VHD times were noisy (20-165 s for the same 19 GB) during the first runs: another session was copying GBs on C: at the same time. From then on these labs take the lock and wait for C: to be quiet.

### Export/import
(pending: waiting for the shared lock)

## Conclusions
- Adopted: GpuVM's own restore points (`New/Restore/Remove/Get-GpuVMRestorePoint`).
- Adopted: `Compress-GpuVMDiskCopy` (read-only Retrim + Quick) in `New-GpuVMTemplate` and `Export-GpuVM`.
- Still to measure: a real template from a big machine (the 159 GB of lab 016), boot after going back, and pairing time of a disposable or imported machine with a new identity.
