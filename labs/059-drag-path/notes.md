# Lab 059: drawing with `drag` paths

**Why.** In lab 057 (`labs/057-capture-broker/notes.md` §4) Claude drew four Paint pictures by writing C# /
`mouse_event` PowerShell scripts inside the machine: 6 runs failed on PowerShell pitfalls (~1-2 min each) and one
painted nothing for 9 minutes. Agents need to draw with the tools they already have.

**What changed (agent 0.4.7, MCP `drag`).**
- MCP `drag` takes, besides `x, y, toX, toY`: `path` ([[x, y], ...] in screenshot pixels), `strokes` (several paths,
  each pressed and released on its own), `button` (left/right/middle, also for the plain drag) and `durationMs`
  (time for all strokes; default 1500 desktop pixels a second, at most 60 s). At most 4000 points and 200 strokes per
  call (the guest request frame is 64 KiB; 4000 points are ~38 KB of JSON). `act` takes the same `drag` items, with
  the 4000 points counted over the whole call. Points map like clicks (`Shot::strokes_to_full`, zoomed screenshots
  included) and the broker waits for the drawing (`ms` is in the input budget).
- Guest `input.act` `drag{strokes:[[x0,y0,x1,y1,...],...], button?, ms?}`: for each stroke, the usual checks (secure
  desktop, foreground, elevated windows under a sample of up to 64 of its points), move to the first point, press,
  10 ms, then moves interpolated at most 3 px apart, each at its time along the stroke (even speed; the strokes share
  `ms` by length), release, 20 ms before the next stroke. Points already due go out together, so a late wake-up never
  slows the stroke. Every 40 ms it checks for a cancel (the person took control: the host cancels the request) and
  for the secure desktop; either stops the stroke and the button is released where the pointer is. The guest's
  deadline for the request includes the drag's `ms`.

**Unit tests.** `guest/agent`: `strokes_are_checked_against_the_screen`, `densify_fills_gaps_and_keeps_the_ends`,
`stroke_times_share_the_duration_by_length`. `app/src-tauri`: `geometry::strokes_map_like_clicks`,
`geometry::drag_time_at_the_default_speed`, `tests::drag_along_paths_and_strokes` (path, strokes, button, durationMs,
broker wait, act, every error message, the 4000-point cap across act).

## The real check (not run yet)

There was no RAM for a second VM on 2026-11-21 (agent-tpl's profile needs 4 GB; the PC had 2.8-4.2 GB free while the
coordinator's machine ran), so the coordinator runs this after installing the app and agent 0.4.7.

Run in an elevated PowerShell, on an agent machine with agent 0.4.7 (the script refuses older ones):

```powershell
.\labs\059-drag-path\run.ps1 -Name <machine>
# open out\before.png, read the white canvas box in desktop pixels
.\labs\059-drag-path\run.ps1 -Name <machine> -Canvas <x>,<y>,<w>,<h> -CancelTest
```

It talks to the agent directly (Invoke-GpuVMAgent), so it works with the old MCP server too. Then copy
`out\paint.png` next to these notes as `paint.png` and fill in the table.

**Expected.**
- The picture: a closed circle, a 4-turn spiral, a five-point star (5 straight lines), a wave and 3 dots in the lower
  half; three small spirals at the top. All lines continuous, the circle and spirals round (no visible corners) at
  2000 and 500 ms; at 100 ms the small spiral may turn slightly polygonal (Paint reads fewer moves than it gets).
- Timings: `agentMs` ≈ the drag time + ~10 ms per stroke (press) + ~20 ms between strokes + one foreground check
  per stroke; e.g. the 500-point spirals ≈ 2.0 s, 0.5 s and 0.1-0.15 s; the circle+spiral call at 1500 px/s ≈ its
  length / 1.5 (about 1.5-2.5 s on a 1920x1080 canvas). ms per point = agentMs / points.
- `-CancelTest`: the 10 s spiral ends after ~2 s with an error (`paused` / `cancelled`), the button released (the
  next click in Paint doesn't keep drawing), and the spiral is cut at about a fifth.

| Call | Points | ms asked | agentMs | ms / point | Looks right |
|---|---|---|---|---|---|
| circle + spiral (default speed) | 861 | (1500 px/s) | | | |
| star + wave + dots (9 strokes) | 94 | (1500 px/s) | | | |
| spiral 500 pts | 500 | 2000 | | | |
| spiral 500 pts | 500 | 500 | | | |
| spiral 500 pts | 500 | 100 | | | |
| cancel at 2 s of 10 s | 1500 | 10000 | | | |

**Through the MCP (after installing the new app).** The same with the tool itself, e.g.
`drag {machine, strokes: [[[300,300],[400,300],[400,400]], [[500,500]]], durationMs: 800}` on Paint's canvas, then a
screenshot.
