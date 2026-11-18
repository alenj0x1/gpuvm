# Lab 043: files from the PC into a machine, between machines, and the drop on the viewer

Questions:
1. Can a file dragged from Explorer reach the viewer's window? The viewer runs at Low integrity with a restricted
   token inside a job, and UIPI blocks some messages from lower to higher integrity.
2. How should the app take a drop without trusting the viewer?
3. Which channel copies files into a running Windows guest best: PowerShell Direct (`Copy-Item -ToSession`), our own
   stream over PowerShell Direct, `Copy-VMFile` (Guest Service Interface) or a shared disk?

Machine: i5-12400, 16 GB, NVMe (KINGSTON SNV2S1000G). Guest: `win-gpu` (Windows 10, 8 vCPU, 6 GB), the only machine
on the PC during the lab. All copy runs held `C:\GpuVM\.lab-lock` and waited for C: to be quiet (< 50 MB/s).

## 1-2. Drop on the viewer (`drop/run.ps1`, `drop/DropProbe.cs`)

The probe launches a "viewer" window with the app's own sandbox (Explorer's token, restricted like `lowbox.rs`:
Administrators deny-only, no privileges, Low label, a job with the same UI limits). A Medium drag source, also run
with Explorer's token, presses the button on its own small window, moves onto the target and lets go. If anything
else is under the pointer, the drag is cancelled. The pointer moves for ~2 s per case.

| Case (5 rounds) | DragEnter at the target | Drop with paths |
|---|---|---|
| Medium target (baseline) | 5/5 | 5/5 at the target |
| Low, restricted target in a job (the viewer) | 5/5 | 5/5 at the target |
| Low target reports "drag", the app's Medium window appears over it | 5/5 | 4/5 at the app's window* |

\* The failed round ended after 0.6 s, before the pointer moved (the source's drag loop ended early). The likely cause
is that the person used the mouse during that round. The probe didn't record input (`GetLastInputInfo`), so this is
unconfirmed. Next time, record input (lab-craft §2).

Findings:
- UIPI does not block an OLE drop from Medium to Low: the viewer can receive drags.
- First probe versions were wrong in three ways, all fixed: `SetCursorPos` alone never drives OLE's drag loop
  (it needs real button input). An `INPUT` struct of the wrong size made `SendInput` fail silently. And tokens made
  with `CreateRestrictedToken` from the elevated shell broke the drag after `DragEnter`, while Explorer's real token
  works (lab-craft §2: run the thing with the rights it has in production).
- Showing the app's window **activated** made Windows cancel the drag in 4/5 rounds. Shown without activation
  (`WS_EX_NOACTIVATE`, `SWP_NOACTIVATE`) it took 14/15 drops across runs.

Decision (security): the viewer never names files. Its drop target only sends `drag` and refuses the drop. The app's
own window (owned by the viewer, never activated) takes the drop with Windows' paths. A viewer taken over by its
streaming host can at most make the drop area show for 1.5 s. It can't ask the app to copy files of this PC.

## 3. Copy methods (`run.ps1`)

Random (incompressible) data. 2 rounds, method order reversed in round 2. Times in ms. Results:
`out/results-20261118-074643.jsonl`.

| Set | psd (Copy-Item -ToSession) | gsi (Copy-VMFile) | tar stream (ours, PS Direct) | disk (shared disk) | relay VM→VM (PS Direct, memory only) |
|---|---|---|---|---|---|
| 1 MB (×3 per round) | 155-307 | 43-220 (r2: ~4,000 the first calls after enabling GSI) | 245-352 | 3,069-3,913 | 200-322 |
| 2,000 files, 4-64 KB (67 MB) | 31,402 / 32,398 | 44,646 / 53,335 | 15,458 / 17,886 | 4,911 / 5,891 | 82,817 / 83,716 |
| 1 GB | 103,188 / 108,650 (9.4-9.9 MB/s) | 13,481 / 17,345 (59-76 MB/s) | 221,315 / 227,406 (4.5 MB/s) | 5,920 / 6,528 (157-173 MB/s) | 173,766 / 184,129 (5.6-5.9 MB/s) |

Notes:
- PowerShell Direct serializes `byte[]` as base64 in both ends. One session tops out near 12-15 MB/s with 4-16 MB
  chunks (microbenchmark: 1 MB 6.9, 4 MB 11.9, 16 MB 15.2 MB/s, round trip 5.5 ms). Our tar stream adds the guest's
  `tar.exe` pipe and lands at 4.5 MB/s for big files. It still wins for many small files (one round trip per 4 MB,
  not per file): 2x faster than `Copy-Item`, 3x faster than `Copy-VMFile`.
- `disk` includes detaching the disk from the running VM, mounting it on the host, robocopy, attaching it again and
  robocopy inside the guest. It is the fastest for big data, but the host mounts a file system that a guest wrote
  (parsing untrusted NTFS in the host's kernel), and it needs a disk sized for the copy.
- `gsi` needs the Guest Service Interface integration service, which GpuVM leaves off. While on, the guest has one
  more VMBus channel to the host's worker process for that VM. Copy-VMFile only copies host → guest and writes as
  SYSTEM in the guest.
- First pilot runs (5-10 MB/s for everything, even the shared disk) were thrown away: another session's VHD compact
  was writing 1.7 GB/s to C: without the lock. `run.ps1` now waits for a quiet disk before each sample and records it.

### Several PowerShell Direct sessions at once (`parallel.ps1`)

512 MB written by N sessions, each writing every N-th 4 MB part at its offset. 2 rounds, with the lock held.
Results: `out/parallel-*.jsonl`.

| Sessions | Round 1 | Round 2 |
|---|---|---|
| 1 | 9.5 MB/s | 10.6 MB/s |
| 2 | 20.5 | 18.7 |
| 4 | 30.9 | 33.2 |
| 8 | 41.3 | 42.8 |

Decision: files of 16 MB or more go through up to 8 sessions at once, and smaller files keep the tar stream. This
stays on the channel GpuVM already uses, with no new attack surface. Copy-VMFile (59-76 MB/s) would need the Guest
Service Interface turned on. The shared disk (157-173 MB/s) needs the host to mount a file system written by the guest.
Both widen what a guest can reach, so neither was adopted (build-approach §4b).

### The product, measured (`Send-GpuVMFile`)

- 1 GB from the PC: 31,952 / 30,144 ms (32-34 MB/s), hash equal (`out/product-1gb.jsonl`). The old single-stream code
  took 221 s, `Copy-Item -ToSession` took 103-109 s.
- Dropped on the real viewer in the installed app (a 300 MB file and a folder of 12 photos): the progress card went from
  0 to 100 % in ~12 s, and 13 files arrived with an equal hash.
- VM -> VM, `win-gpu` -> `lab045-win2` (a 64 MB file and a folder of 200 small files and a name with ñ, selected in
  win-gpu's File Explorer and read with `Get-GpuVMExplorerSelection`): 16.3 / 15.2 s (4.1-4.4 MB/s), hash equal,
  repeated names became "(2)" (`out/vm2vm-*.jsonl`). The small files go one round trip each from the source VM:
  that is the next thing to speed up (pack them in the source VM).

- Small files from another VM, read several per round trip (200 files of 0-32 KB, 3.2 MB): 1,708 / 1,214 / 997 ms
  with the lock held at 11:21, hashes equal (`out/remeasure.jsonl`). A first run at ~10:40 (1.3 s) fell inside a
  stray stream of another lab and was repeated. Before batching, these went one round trip each.

### Bugs the real run found (all fixed)

- SDL accepts dropped files by default (`DragAcceptFiles`). Windows handed the paths to the viewer through
  `WM_DROPFILES`, and the app's drop area never showed. The viewer now turns SDL's drop events off and only sends `drag`.
- wry registers its drop target on the web view's child windows when the window is built. The drop window is built
  hidden, so Windows gave the drop to the web view, which refused it. An invisible (alpha 1) native window with its
  own OLE drop target now takes the drop.
- The drop area was shown with Win32 and hidden with Tauri's `hide()`, which did nothing (Tauri thought it was
  hidden), so it stayed over the picture. It is now hidden with Win32 too.
- PowerShell unrolled byte arrays assigned through `if`/`@()`, and `Wait-Job -Timeout 0.5` meant 0 seconds. The
  first real drop hung at 1 % and its bridge spun the CPU. Recorded in tool-pitfalls §9g.
