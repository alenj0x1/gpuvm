# Open time

**Hypothesis:** Opening a VM is slow because of steps GpuVM runs on every open, not only because Windows boots; and the "Abrir" button comes back before the picture shows up, so the VM can be opened twice.

## Procedure

`run.ps1` (elevated, PowerShell 7, in the signed-in user's session) runs `Connect-GpuVM` as the app does and times every step inside it (wrappers in the module's scope, same parameters as the originals). After it returns it watches Moonlight: its window, its log line "Video stream is" (first frame) and the window's brightness. Cold runs shut the VM down first; warm runs open it while it is on. Moonlight is closed between runs.

## Observations

### Runs of Nov 8, 2026 (win10, 7 GB, 1920x1080 at 120 FPS)

| Run | Button back to "Abrir" | Moonlight window | First frame | Waiting for Windows |
|---|---|---|---|---|
| cold 1 | 197.6 s | +1.3 s | +16.7 s | 163.7 s |
| cold 2 | 76.7 s | +0.5 s | +17.1 s | 43.5 s |
| warm 1 | 27.6 s | +0.0 s | +3.2 s | 1.8 s |
| warm 2 | 25.2 s | +0.0 s | +2.6 s | 1.7 s |
| warm 3 | 24.6 s | +0.0 s | +2.8 s | 1.7 s |

Steps on every open (warm, seconds): pending guest work 7.8-8.6, guest display resolution 4.5-4.9, capture mode 2.5-2.9, guest audio 2.7-2.9, audio sink 1.6-2.0, console session 1.5-1.8, guest ready check 1.7, Moonlight launch 0.9-1.3, endpoint 0.4-0.7, network isolation 0.5. Almost all of them are separate PowerShell Direct calls; together they are about 22 of the 25 s.

- On a cold open the first PowerShell Direct call blocks about 30 s while Windows boots before it fails, so "Esperando a que Windows arranque" shows up only at 32 s.
- After a cold open, the stream shows nothing for 17 s after the button is free again; when the VM was already on, 3 s. Cold opens change the VM's display to 1920x1080@120 right before Moonlight starts, which matches lab 008 (a display mode change makes Sunshine re-test its encoders: 10-15 s).
- The brightness check did not work: the Moonlight window reads 31-38 from the moment it appears (its own screen, not a black frame), so "visible picture" is taken from the log's first frame only.
- An earlier attempt failed with "La VM necesita 6 GB libres y hay 6.1 GB": the check also keeps 0.3 GB of margin, which the message doesn't say.

### After the changes (same day)

`Connect-GpuVM` now shares one PowerShell Direct session, remembers what it did since the guest's last boot (display mode, capture mode, audio sink), only grows C: when the system disk changed size, polls Windows and Sunshine every 3 s instead of 10, sets the display before the rest of the guest work, and waits for Moonlight's first frame before returning (a second click brings the open Moonlight to the front).

| Run | Before | After |
|---|---|---|
| warm (VM on) | 24.6-27.6 s + 2.6-3.2 s to the first frame | 7.0-10.3 s, first frame included |
| cold (VM off) | 76.7-197.6 s + 17 s to the first frame | 72-86 s, first frame included |

- The button now comes back when the picture is there ("Conectando la imagen" while Moonlight waits).
- The black seconds after a cold start are not GpuVM's display change: the guest reported no change (`changed: false`) and Sunshine still logged "Encoder reenumeration is required" on the first session after boot (5-11 s). Hypothesis rejected; the display-first order stays because it helps when the mode does change.
- Guest audio varies a lot right after boot (1-16 s): the speaker reattaches about a minute after Windows starts.
- A first PowerShell Direct call while Windows boots still blocks about 30 s; Windows itself is ~36 s of every cold open.

### Heartbeat and audio in the background (same day)

Waiting for Hyper-V's heartbeat before the first PowerShell Direct call, and checking the speaker on a second connection while the rest is prepared.

| Run | Windows ready | Sunshine ready | Total, first frame included |
|---|---|---|---|
| cold 1-3 | 9.6-10.4 s (was ~36 s) | 47-58 s | 81-90 s |
| warm | - | - | 9.8 s |

- Windows answers ~26 s sooner, but the total did not drop: the wait moved to Sunshine, which answers 45-58 s after power-on.
- Sunshine's own startup (its log, 3 cold boots): ~8 s before it lists displays, then ~16 s looking for gamepads ("ViGEmBus is not installed", then "No gamepad input is available" 8 s later), then 11 s testing encoders before its web API answers. The first session tests the encoders again (10 s, "Encoder reenumeration is required").
- The speaker comes back ~60 s after power-on (usbip-win2), so the audio check still waits 7-17 s after Sunshine answers.

### Gamepads and not waiting for the speaker (same day)

ViGEmBus 1.22.0 is installed once per VM (pinned SHA-256, matching Chocolatey's verification file; Authenticode signer checked inside the guest), and Moonlight opens as soon as Sunshine answers when the speaker is not back yet; the speaker is finished after the picture is up.

| Run | Picture on screen | Job done (audio included) |
|---|---|---|
| cold 1-2 | ~55 s (was 77-90 s) | 68-69 s |
| warm | 7.5-12.9 s | same |

- With ViGEmBus, Sunshine's startup lost ~3 s, not 16: the gamepad warnings are gone, but its start to "encoders found" still takes ~33 s.
- Sunshine detects the controller ("Gamepad 0 will be Xbox 360 controller").
- When the session starts before the speaker exists, Sunshine logs "Couldn't find the specified virtual audio sink" and, ~8 s later, "Reinitializing audio capture" once the speaker is back. Not yet checked by ear that the sound then comes from GpuVM's speaker.

## Conclusion

Confirmed and mostly fixed. The job ended when Moonlight's process starts, 3 s (warm) to 17 s (cold) before the first frame, which is how the VM got opened twice. A warm open spends about 22 s repeating guest work through separate PowerShell Direct calls. Adopted: waiting for the first frame, one session, work once per boot, C: only when the disk grew. Also adopted: Windows readiness from the Hyper-V heartbeat, the speaker check in the background, ViGEmBus, and opening Moonlight before the speaker is back. Still open: Sunshine's ~33 s start and its encoder re-test on the first session after boot, and an ear check of the sound when the speaker comes back mid-session.
