# Lab 062: a screenshot right after an action shows it

Question: a `screen.capture` taken right after `input.act` (a drag answered `done`) came back without the drag; the
next capture had it. Why, and how to make the first one right without slowing every screenshot much?
Machine: an agent machine (Windows 10 19045, GpuVM display 1920x1080, Paint maximized), agent swapped in place.

## Cause

Two, one under the other:

1. **The capture's pool filled up and dropped new frames.** WGC delivers frames into a pool of 2 buffers; agent
   ≤ 0.4.8 only emptied it when a screenshot was asked for. On GpuVM's display Windows delivers ~180 frames a second
   even when nothing changes (measured: `settleFrames` ≈ 6 per 30 ms on a still screen), so right after each
   screenshot the pool held the next 2 frames and every later one was dropped. The next screenshot got those 2 old
   frames: the screen from just after the previous screenshot, before the drag.
2. **The action's last frames arrive after it answers.** With the pool emptied continuously (fix 1), a screenshot
   taken the moment the request arrives still missed about half of a short stroke (`settleMs 0` below): Paint draws
   the end of the stroke, and the cursor, in frames composed a few ms after `input.act` returned.

Frames can't tell a change from a still screen here (they keep coming either way; dirty regions need Windows 11 24H2),
so "wait until the screen is quiet" doesn't work: an earlier try waited 100 ms on every screenshot.

## Fix (agent 0.4.9, `guest/agent/src/capture.rs`)

- The pool's `FrameArrived` handler takes every frame as it arrives and keeps a copy of the newest, so the buffers
  never stay full.
- A screenshot takes the newest frame `settleMs` (default 30, ≤ 1000) after its request.
- Locking: the handler holds the D3D device while it waits for the screenshot's lock, so the screenshot never calls
  into Direct3D or the pool under that lock (the first version did and hung, locally and on the machine: `gpuvm-agent
  diag` reproduced it in a second). The lock only guards the newest frame's pointer; the device is multithread
  protected for the two threads.

Unit test: `a_screenshot_takes_the_newest_frame_once_the_screen_had_time_to_show_the_last_action` (the decision,
`step()`); 17 pass in `guest/agent`.

## Results

`fresh.ps1`: per round capture A, drag a stroke, capture B at once, wait 600 ms, capture C. Fresh = inside the
stroke's rectangle B differs from A and matches C.

| agent | settleMs | fresh (10 drags) | grab alone, median | round trip alone, median |
| --- | --- | --- | --- | --- |
| 0.4.8 | – | **0/10** (B identical to A: no stroke at all) | – | 24.6 ms |
| 0.4.9 | 0 | 0/10 (half of each stroke missing) | 4.9 ms | ~15 ms |
| 0.4.9 | 10 | 10/10 | 17 ms | ~29 ms |
| 0.4.9 | 20 / 30 / 45 / 60 | 10/10 each | 27 / 38 / 51 / 68 ms | |
| 0.4.9 | default (30) | **10/10** | 38 ms | 47.5 ms |

The 0.4.8 row used 520 px strokes (the first version of the script); the others 40x15 px strokes on a grid.
Cost while the capture is open (until 30 s after the last screenshot): the helper at 2.2 % of one core; 0 % once it
closes. The default is three times the smallest value that worked; a slower app can still need the MCP `delayMs`.

## How to run

Elevated, on a machine nobody else is using, classic Paint maximized in front (pencil or brush), 1920x1080:

```powershell
cd labs\062-capture-fresh
.\fresh.ps1 -Name <machine>                              # the agent's default
.\fresh.ps1 -Name <machine> -Settle 0,10,20,30 -Row 0    # compare values (agent 0.4.9+)
```

Strokes go on a grid in the canvas' bottom strip (column = round, row = one per value; 7 rows fit, `-Row` picks the
first), so the canvas needn't be cleared. Pictures: `out\<time>\` (git-ignored); `-From <dir> -Row <n>` analyzes
them again.

## Lessons

- A WGC frame pool that isn't drained keeps the frames from right after the last read and drops the rest; on a
  display that delivers frames continuously that is always the wrong picture.
- Don't take a lock in a WGC `FrameArrived` handler that is held across D3D calls elsewhere: the handler holds the
  device meanwhile. Reproduce capture changes on the host first with `gpuvm-agent diag` (a hang shows in seconds).
- A lab that draws in the same place every run measures overlap, not freshness: give every stroke new pixels.
  Keyboard shortcuts to clear Paint opened its Open dialog instead; a grid of positions needs no clearing.
- PowerShell variables are case-insensitive: `$alone = …` overwrote the `[int]$Alone` parameter.
