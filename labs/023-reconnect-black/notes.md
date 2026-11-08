# Black picture after reconnecting

**Hypothesis:** When Moonlight connects to a VM that is already on, the picture stays black for a long time (5-58 s in lab 022) because Sunshine's capture keeps restarting at the start of each session, not because of the network, the encoder or a display mode change. Another capture method avoids it.

## Procedure

- `run.ps1` (elevated): starts the VM if it is off, sets Sunshine's log to debug (restored afterwards), starts `tools/latency/motion-target.ps1` in the VM and opens Moonlight `-Count` times in a row with the VM's saved settings and no display change in between. Per session: Moonlight's first frame (its log), when the bar is seen moving on the host screen (`pictureSec`, brought to the front before every probe, focus losses counted), and from Sunshine's log the time from "Executing" to "Capture format" (`sunshineSec`, DDX only). `-Capture wgc` switches Sunshine to Windows.Graphics.Capture through GpuVM for the run and back. `restore.ps1` puts `sunshine.conf` back (also alone, after an interrupted run).
- Sunshine source (tag v2026.914.233613), read for this lab: "Desktop resolution" is printed only when DDX (`duplication_t::init`) starts again; "Capture format" only when DDX gets its first real desktop frame (`display_vram.cpp` L1407-1429); until then Sunshine encodes a black placeholder frame "to let Moonlight know that we're alive" (`video.cpp` L2444-2493). Capture restarts from `IDXGIFactory::IsCurrent() == false` or `DXGI_ERROR_ACCESS_LOST/ACCESS_DENIED` are not logged at any level. WGC sets the format when it starts, so it never waits on that placeholder.

## Observations

### Runs of Nov 8, 2026 (win10, 1920x1080 at 120 FPS, 10 reconnects each)

| Run | Picture on screen (s) | Sunshine first real frame (s) | Never shown |
|---|---|---|---|
| DDX (`out/20261108-165353-baseline`) | 39, 13.7, 10.7, 10.7, -, 25.3, -, -, 46.4, 3.6 | 15.5, 10.6, 0, 0, 26.1, 23.2, 48.2, 50.7, 5.3, 0 (median ~13) | 3 |
| WGC (`out/20261108-170718-wgc`) | 9.5, 2.6, -, 2.6, 2.6, 2.6, 2.6, 2.6, 2.6, 2.6 | not logged with WGC | 1 |

- DDX: in each slow session Sunshine's log repeats the display start ("Desktop resolution") every ~0.75 s, up to 40 times, and creates and tears down the NVENC encoder every 5-7 s until "Capture format" appears; when it doesn't restart (sessions 3, 4, 10) the picture shows in 3.6-11 s. Moonlight's "first frame" comes after ~2 s in every session: it is the black placeholder.
- In sessions 1, 5, 7, 8 and 9 of the DDX run Sunshine had real frames well before the meter saw them: the Moonlight window had been covered by another window during the run. The script now brings Moonlight back before every probe; the WGC run lost focus only in session 3. The Sunshine-side times above don't depend on that.
- WGC: 9 of 10 reconnects showed the picture 0.6 s after Moonlight's first frame (2.6 s from launch; the first one 9.5 s). Session 3 stayed on Moonlight's "Starting input stream establishment..." (its control/input connection, before any picture) until the 60 s timeout; seen once, cause not found in the log. WGC logs "Failed to sync desktop to thread" and two "Can't ... on this version of Windows" warnings at each start, harmless here.
- Known WGC trade-off (lab 009, `guest/capture-mode.ps1`): Sunshine runs in the user's session instead of as a service; it captures games in exclusive fullscreen (DDX shows them black on the virtual display), but Windows administrator prompts (secure desktop) don't appear in the stream.
- The first interrupted attempt hung 20 min waiting for an IP from a VM that was off: `Get-GpuVMEndpoint` now fails at once when the VM is off, saved or paused.

## Conclusion

Confirmed: the black picture after reconnecting is DDX capture restarting silently at session start; WGC shows the picture in about 2.6 s in 9 of 10 reconnects. WGC as the default depends on answering administrator prompts another way (labs 025-026).
