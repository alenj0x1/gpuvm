# DDX restarts at session start

**Hypothesis:** Sunshine's DDX capture (the one that shows Windows administrator prompts) restarts at the start of each session (lab 023) because of something in the VM's picture, such as a full-screen window, that can be avoided, so DDX could start as fast as WGC.

## Procedure

`run.ps1` runs lab 023's reconnect measurement with DDX, 8 reconnects per case, changing only what the VM shows: the bar full screen (`motion-target.ps1`), the bar in a normal window over 70 % of the screen (`-Windowed`), or nothing (the plain desktop). Measured from Sunshine's log: how many times the display starts again ("Desktop resolution") per session, and the time from "Executing" to "Capture format" (DDX's first real frame).

## Observations

### Run of Nov 8, 2026 (`out/20261108-172842`, win10, 1920x1080 at 120 FPS)

| What the VM shows | Capture restarts per session | First real frame (s) |
|---|---|---|
| Bar full screen (whole picture changes) | 9, 10, 9, 17, 9, 110, 1, 22 | 6.4, 7.8, 6.4, 11.2, 6.4, 69, 1.0, 14.2 |
| Bar in a window (part changes) | 131, 81, 58, 76, 21, 98, 122, 55 | none, 49.4, 37.8, 49.8, 14.6, 61.4, 76.4, 33.7 |
| Plain desktop (nothing changes) | 62, 63, 41, 65, 19, 67, 59, 68 | none in 30 s except 19.2 and 11.0 |

- The first counts of each run (16) include Sunshine's start; the table starts at the first session.
- The less of the picture changes, the more DDX restarts and the later its first real frame: with a still desktop, which is what a person usually has when connecting, the stream can stay black until something on screen changes. A full-screen window is not the cause (it was the fastest case).
- Lab 023's `sunshineSec` of 0 meant both "no restart" and "no real frame at all"; the restart count is the reliable measure.
- WGC, in lab 023, showed the picture 0.6 s after Moonlight's first frame in 9 of 10 reconnects.

## Conclusion

Rejected: the full-screen window is not what makes DDX restart, and nothing tried brings DDX near WGC; even with the whole picture changing, its first real frame takes about 6 s. Next: WGC by default, with GpuVM showing and answering the administrator prompts it can't stream (labs 025-026).
