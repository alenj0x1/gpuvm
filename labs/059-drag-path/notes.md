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
- `-CancelTest` (runs `cancel-mcp.ps1`, see below): the MCP `drag` answers with the take-over error right after the
  suspend, the left button is down in the machine for ≈ the 2 s, and the spiral is cut at about a fifth of its time.

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

## The take-over check (2026-11-21, an agent machine, agent 0.4.8)

**The first run "failed" because of the lab, not the agent.** The coordinator's `-CancelTest` drew the whole 10 s
spiral and answered ok after 10015 ms although `Suspend-GpuVMAgent -Reason control` ran at 2 s. The drag went through
`Invoke-GpuVMAgent`, the person's own request (module pipe, no agent session), and taking control cancels only agent
sessions' requests (`cancel_where(.., |p| p.client.is_some())` in `app/host/src/agent.rs`): the person's own work
is not stopped by the person taking control. Nothing reached the guest to stop.

**What does stop it.** `cancel-mcp.ps1` does it the way it happens: an MCP session (`gpuvm.exe --mcp`, the installed
app) takes the machine and draws a 1500-point, 10 s spiral with `drag`; another thread runs the suspend; a pointer
log runs inside the machine (exec.run, PowerShell reading `Cursor.Position` / `MouseButtons` every ~5-10 ms on its
own clock).

| Run | Cancel | Answer after the cancel | Left button down in the guest | After |
|---|---|---|---|---|
| MCP drag, suspend at 2.3 s | `Suspend-GpuVMAgent -Reason control` | 0 ms ("The person took control of an agent machine…") | - | button `None` |
| MCP drag, suspend at 4.3 s | same | 1 ms | - | button `None` |
| MCP drag, suspend at 2.3 s | same | 0 ms | - | pointer still, button `None` |
| input.act, host timeout at 2 s (same cancel frame) | host `cancel` | 2014 ms call | **1994 ms**; last move 16 ms after, released | still |

So the guest stops within one 40 ms check of the cancel and releases the button where the pointer is. The spiral
stops at radius ≈ 0.45 of the full one at 20% of the time, as it should: the time is shared by length and a
spiral's length grows with the square of its radius.

Two things seen on the way, not from this change: the agent's screenshots were stale for a while (a spiral that
was already drawn showed up only in a later capture; another session is fixing it in capture.rs), and after agent
0.4.9 was installed `screen.capture` stopped answering (timeouts) while `exec.run` answered in 43 ms, so the last
run couldn't start (the MCP drag needs a screenshot first).
