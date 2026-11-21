# Lab 057: an agent session under the microscope (frozen viewer, black flashes, recordings, how the agent worked)

Source: a real Claude Code session (one hour on an agent machine: Firefox + YouTube, then four drawings in Paint), its transcript, the guest's logs and event log,
and the 35-minute recording the app made of it. Then reproduced and fixed on the same machine.

## 1. The viewer froze at 11:25 (CaptureService crash)

What he saw: the viewer stuck on an old picture while the agent's screenshots showed the drawing moving on; closing
(Ctrl+Shift+Alt+Q) and reopening brought it back.

| evidence | what it says |
| --- | --- |
| recording, keyframe differences | picture identical from **11:25:09** to the reopen at 11:31:43; stream fps 180 → 69 at 11:25:06 (Sunshine repeating the last frame) |
| agent transcript | `screenshot` failed at 11:25:06 with `0x800706BE` (RPC call failed), worked 4 s later |
| guest event log | 11:25:07 `svchost.exe_CaptureService` crashed in `captureservice.dll` 10.0.19041.789 (0xc0000005); SCM restarts it after 10 s |
| Sunshine log | nothing between 11:05:08 and the client's disconnect at 11:31:43: the helper stayed "alive" |

Cause: WGC sessions live in the per-user CaptureService. When it dies the helper's session gets no Closed event and
no frames; the lab-056 watchdog sees an idle helper (callback done, delivery waiting) and leaves it. The agent's own
capture reopens on the next call, which is why its screenshots kept working.

Fix (gpuvm-sunshine, helper): the stall probe notes CaptureService's process ids when the capture starts and checks
them every second; if they change, the helper ends and Sunshine starts a new one.

| run (`crash.ps1`: end CaptureService's process, read the guest's logs) | result |
| --- | --- |
| baseline, helper 74cd902e | no restart in 40 s; probe logs "no FrameArrived ... cb:done dl:wait"; picture frozen |
| fix-1, fix-2, fix-3 | helper restarted after **1.4 / 2.0 / 1.8 s**, capture_fps ~180 again |

Also: the helper's log was one file rotated 5 times, and Sunshine starts the helper ~10 times per viewer open, so the
log of the frozen session was gone within minutes. Now one file per run in `Roaming\Sunshine\wgc-helper\`, 40 kept.

## 2. Black flashes in the picture

What he saw (phone videos 12.26.06, 12.31.23, 12.34.17): dark areas with straight and diagonal edges flashing over
the picture, sometimes the whole screen.

They are **in the stream** (the recording has them, so not the viewer): single frames, fixed by the next one, showing
a half-composed desktop (black, wallpaper, window quads half rasterized with stair-step block edges). The helper got
the WGC frame before Windows had finished drawing into it, and released it right after queueing its copy.

`glitches.py` counts frames where ≥0.4 % of the picture turns near-black for that frame only:

| recording (~76 s each, animated clock on screen) | glitch frames per minute |
| --- | --- |
| session recording, 2 min at 11:16 | 28 |
| before (helper with broker watch) | **80** |
| after: wait for the copy on the GPU before releasing the frame | **37.5** |
| + wait 3 ms before copying (rejected) | capture fell from ~160 to 48 fps |

Kept: the wait for the copy (D3D11 event query, avg 0.5-3.4 ms, max ~15 ms, no timeouts). **Not solved**: half the
flashes remain, because WGC hands over frames Windows is still drawing (GPU-P virtual display). Next idea, not done:
deliver frame N-1 when frame N arrives (it is surely finished) and a held frame after ~10 ms of quiet, at the cost of
one composition frame of latency.

## 3. Recordings he can't play

The viewer records the stream as it comes; with codec on auto, Moonlight chose HEVC, which Windows' players don't open
without the Store extension. App: with codec on auto and no HEVC decoder in Windows, the viewer is opened with
`--video-codec H.264`. Sizes: 4.3 GB for 35 min and 6.4 GB for 40 min (180 fps, ~16 Mbps): ~7 GB per hour of agent work.

## 4. How the agent worked (60 min, 7 requests, 250 tool calls)

| tool | calls | total | note |
| --- | --- | --- | --- |
| run | 67 | 32.8 min | 7 runs over 60 s (drawing scripts 104-291 s); **28 were `Start-Sleep`** used as a wait |
| screenshot | 83 | 3.4 min | 0.2-0.6 s alone; 3-9 s when sent next to a `run`: it waits behind it |
| click / drag / key / type | 68 | 2.7 min | ~0.7 s each when sent together (serialized) |
| create_disposable / open_viewer | 1 / 1 | 59 s / 47 s | |
| offer_file / offer_status | 3 / 2 | 40 s | all three accepted; copies in Downloads\GpuVM (he liked this) |

- Drawing: Claude wrote C# + `mouse_event` PowerShell scripts in the guest. 6 failed (functions `H`/`PWd` clashing with
  aliases, `$R` = `$r`, int types), ~1-2 min each; the first one painted nothing for ~9 min until he stopped it
  ("no veo nada creando"). Lesson already added by that session to tool-pitfalls.
- `winget` isn't in the agent template: Firefox went through a direct download (19 s, signature checked).
- While a long `run` drew, the agent could not take screenshots (they queue behind it), so it drew blind.
- Saving three PNGs took ~1 min of clicks in Save As dialogs.

Ideas for agents (to propose, not done): screenshot/input that don't wait behind a running command; a `delayMs` on
screenshot/actions instead of `Start-Sleep` runs; a drag along a path (polyline) for drawing without scripts; winget in
the agent template; recordings at a lower rate/bitrate for agent sessions.

## Side finding

With two machines on, Windows 10 gave the second one (`lab057`) the Intel UHD 730 instead of the RTX 4060 (no
`-InstancePath` on Windows 10, lab 001): no stream. Agent machines can't run two at a time on this PC.

## Lessons

- The recording the app keeps of an agent session is the best instrument: it is exactly what the viewer received.
- A watchdog that only looks inside the helper can't see its capture source dying; watch the source too.
- Per-run logs, or the evidence is gone before anyone reads it.
