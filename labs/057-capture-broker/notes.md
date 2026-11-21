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
| baseline, helper a8ba3a05 | no restart in 40 s; probe logs "no FrameArrived ... cb:done dl:wait"; picture frozen |
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

Kept: the wait for the copy (D3D11 event query, avg 0.5-3.4 ms, max ~15 ms, no timeouts).

### Part 2: measured without anyone at the PC (`flashes.ps1`, `ab.ps1`, `mpo.ps1`)

`flashes.ps1` opens GpuVM's viewer with the labs' own pipe, puts a load on the guest's screen, records 60 s through the
viewer (`record` over the pipe, as the app does), counts with `glitches.py` (which also reports `moving_fps`, to throw
out runs where the screen barely moved) and swaps helper builds without dropping the viewer (`swap-helper.ps1`).

What triggers the flashes is **a video playing in the guest** (the session had a YouTube video in Firefox the whole time):

| load (orig = the helper GpuVM shipped, a8ba3a05) | flashes per minute |
| --- | --- |
| double-buffered clock, ~32 changes/s | 3-6 |
| canvas animation in Firefox kiosk, 140 changes/s | 0 |
| WinForms label clock, repainted whole every 16 ms | 5-8 (58 while the session's Firefox video was still open) |
| the label clock over Firefox playing an H.264 video in a loop | **65-128** |

With the video load the spread from run to run is huge (0 to 167 with the same build and settings), so single runs
mislead. Copy wait vs orig, interleaved pairs: 38 vs 128, 66 vs 112, 1 vs 7, 37 vs 65, 167 vs 0; with the label load
2-3 vs 5-8 in 3 of 3 rounds. It helps most of the time; it doesn't fix it.

Rejected:
- **Hold the newest frame and send the previous one** (sent when the next arrives or after 8 ms): no flashes, but the
  stream changed only 6-18 times a second instead of ~32: it lost frames.
- **Wait 3 ms before copying**: capture fell from ~160 to 48 fps.
- **Multiplane overlays off** (`OverlayTestMode = 5`, the usual fix for black flicker with overlays): one run gave 7
  vs 38, the repeats 112, 7, 66, 1: no clear effect, so GpuVM doesn't set it.

**Still open.** Next leads: whether Firefox decodes the video on the GPU partition (try with hardware decoding off in
the guest), and Sunshine's own WGC path in process (no helper) on the same load, to tell the helper from the GPU-P
display.

## 3. Recordings he can't play

The viewer records the stream as it comes; with codec on auto, Moonlight chose HEVC, which Windows' players don't open
without the Store extension. App: with codec on auto and no HEVC decoder in Windows, the viewer is opened with
`--video-codec H.264`. Sizes: 4.3 GB for 35 min and 6.4 GB for 40 min (180 fps, ~16 Mbps): ~7 GB per hour of agent work.
Checked after install (lab 058's copy): Sunshine created `h264_nvenc` for the viewer, and the agent recording (lab 061's
light mode) came out H.264 at ~30 fps, 0.8 MB for 35 s.

## Follow-ups done the same day (parallel sessions, merged into main)

| lab | what | result on the installed build |
| --- | --- | --- |
| 058 | screenshots/input don't wait behind `run`; `delayMs`; `run` in the background + `run_result` | screenshot during a 30 s run 61 ms (was 3-9 s); delayMs 2000 → 2065 ms |
| 059 | `drag` along `path`/`strokes` | circle, spiral, star, wave, dots drawn in Paint; take-over stops an agent's stroke in 0-1 ms (the person's own module calls aren't cancelled, by design) |
| 060 | winget for `agent` in agent templates | template layer 6 has it; `winget install Microsoft.VisualStudioCode --scope user` as `agent` in 45 s |
| 061 | light agent recordings (H.264 30 fps, constant quality) | 10-35x smaller (160 → 4.6-16 MB/min) |
| 062 | a screenshot right after an action shows it (agent 0.4.9) | 10/10 fresh (0.4.8: 0/10); a screenshot alone 25 → 48 ms |

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
