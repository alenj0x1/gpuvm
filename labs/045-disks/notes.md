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

### Real VM (`real-vm.ps1`, 2026-11-18 09:02-09:35, win-gpu shut down cleanly and started again)
`lab045-real` is installed from the Windows 10 ISO with the balanced profile, 4 GB and 4 threads. "Open" is `Connect-GpuVM -Viewer`: it waits for Windows and Sunshine, then pairs, and opens no window.

| Step | Time |
|---|---|
| Create from the ISO (warm base) | 57-90 s |
| First open (Windows setup + Sunshine + pairing) | 359-466 s |
| Second open | 7.2-7.9 s |
| Create a restore point | 1.3 s |
| Open on the point (boot) | 50.5 s |
| Go back to the point | 1.3 s |
| Open after going back (boot, still paired) | 52.8 s |
| Delete the point (merge of the little written since) | 1.3 s |
| Template from the 16.0 GB disk, with compaction | 19.2 s, **14.66 GB** |

Checks:
- A file written after the point is gone after going back.
- The GPU is still visible in the guest.
- The machine is still paired: GpuVM's pairing state goes back with the point, and so does Sunshine's inside the disk.

**Bug found and fixed on the first run.** After creating a point the VM didn't start: *"Account does not have permission to open attachment ... Access is denied"*. Hyper-V gives each VM an explicit read/write entry (`NT VIRTUAL MACHINE\<VM id>`) on its disk file when it is attached. A new file at the same path doesn't have it, and `Set-VMHardDiskDrive` with the same path doesn't add it. The new top disk now gets the explicit entries of the VM's previous disk file (`Copy-GpuVMDiskAccess`). `points-offline.ps1` checks the entry after creating a point and after going back. The second run booted fine on the point and after going back.

**Disposable copy refused by the disk-room check.** It reported 10 GB available: 127 GB free, minus 97 GB "promised", minus the 20 GB margin. The promised space is what every VM's disk may still grow into, including lab045-real's own 48 GB. A copy of a 64 GB template asks for the full 64 GB. This is GpuVM's existing worst-case rule, the same for every copy of a template. Part 2 exports lab045-real and removes it first.

### Disposable machine on a real VM (`real-vm-3.ps1`, 10:15, after the person chose option B: a disposable reserves 20 GB)
| Step | Result |
|---|---|
| Disk room before | 144.6 GB free, 49 promised (win-gpu), 75 available |
| Create + start a disposable copy of lab045-tpl | 10.5 s |
| Disk room with it on | promised 69 GB (+20, not +64), 55 available |
| First open (new Sunshine identity, the viewer pairs again) | 55.1 s |
| Second open | 7.7 s |
| Export it (template + copy merged, 15.47 GB) | 34 s, 14.44 GB file |
| Sweep after shutdown (VM and folder deleted) | 0.2 s |

- The check "a running disposable is not swept" read 1 instead of 0, but nothing had been deleted (step log): `Remove-GpuVMDisposable` returned an empty list wrapped in a list. The app would have shown a deletion that never happened. Fixed: it returns one name per deleted machine.
- Re-pairing a disposable or imported machine costs about 47 s more than a warm open (55 s against 7.7 s): its new Sunshine identity asks for a new pairing. Reusing a pre-paired identity would save that, but two machines running with the same identity break pairing and streaming. Kept as is: one identity per machine.

### Final check after the security review (`run-all.ps1 -Labs transfer-offline.ps1,real-vm-3.ps1`, 12:2x)
Import no longer mounts the file's disk on this PC. The imported machine is marked `pendingIdentityReset`, and on its first open `Connect-GpuVM` resets Sunshine's identity inside the VM over PowerShell Direct, sets the new web login with `sunshine.exe --creds`, then restarts Windows. Export builds the merged disk in `<root>\.staging` and writes the file only through a handle whose real path was checked.

| Step | Result |
|---|---|
| Disposable: create + start / first open / second open | 7.1 s / 91.1 s / 8.3 s |
| Export refuses a disposable machine | yes (the sweep could delete it mid-export) |
| Sweep after shutdown | 0.1 s, VM and folder gone |
| Export a normal copy of the template (14.71 GB chain) | 120.5 s, 14.66 GB file |
| Import | 38.8 s |
| First open of the imported machine (identity reset in the VM + restart + pairing through the new login) | **77.5 s, paired** |
| Offline: export 11 GB uncompressed / Fastest | 172 s / 178 s (16.5 / 10.7 GB) |
| Offline: import checks (free name, fingerprint, content, disk untouched, marked for the reset, no pairing) | all pass |

- The first attempt with the old host-side login gave 401 on the first open: my reimplementation of Sunshine's salted hash was not what Sunshine expects. `--creds` is Sunshine's own way, and it pairs.
- "Tampered file refused" failed once: the first import still reserved its 64 GB, so the refusal was for disk room. A direct check also found a real bug. A file that isn't a VHDX made the cleanup throw (`.Attached` on nothing, under StrictMode), so the fingerprint message was lost and the folder stayed behind. Fixed: refused with "no coincide con su huella" and nothing left behind.

### Export/import
- Real machines: lab045-real (16.0 GB disk) gives a 14.66 GB file in 36.6 s; a disposable machine (template + copy, 15.47 GB) gives 14.44 GB in 34 s.
- Import on this PC is held back by the full-size disk-room rule: 130 GB free - 49 promised - 20 margin = 61 < 64. With the export file on C: and a second test machine reserving 64 GB, no import fits. It runs once front 2's lab045-win2 is gone.
- A file whose disk is under 64 GB (the offline test VM) failed the profiles' 64 GB minimum. The imported disk now grows to 64 GB on setup.
- Offline VM (`transfer-offline.ps1`, first run): a 11.25 GB disk becomes a 7.48 GB file with `Fastest` compression, in 159 s. The manifest has no DPAPI blobs or paths. That run stopped at the import (a local `$name` overwrote `-Name`); fixed.
- (pending: part 2 on the real VM, and the offline import checks)

## Conclusions
- Adopted: GpuVM's own restore points (`New/Restore/Remove/Get-GpuVMRestorePoint`).
- Adopted: `Compress-GpuVMDiskCopy` (read-only Retrim + Quick) in `New-GpuVMTemplate` and `Export-GpuVM`.
- Still to measure: a real template from a big machine (the 159 GB of lab 016), boot after going back, and pairing time of a disposable or imported machine with a new identity.
