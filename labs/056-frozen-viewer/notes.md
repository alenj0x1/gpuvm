# Lab 056: the viewer froze on agent machines (Claude Code test, 2026-11-21)

Reported by the person after a real Claude Code session: the agent's screenshot showed Firefox but the viewer didn't;
clicking said "You took control" but the pointer never moved; "Recording" showed a square border; a few warnings in
the corner. Reproduced on `repro01` (copy of agent-tpl) through the MCP tools, the installed viewer and the guest's
logs. ~1.5 h.

## Findings

| symptom | cause | fix |
| --- | --- | --- |
| viewer frozen on an old frame (Firefox missing, typed text missing, no pointer) | GpuVM's Sunshine fork, WGC helper: FrameArrived stopped for good 1-2.5 min into every session (3/3), with or without input; keyboard and mouse did reach the guest (Notepad got the text, the pointer moved). A stall probe (per-thread stage + watchdog) caught the callback waiting for the D3D context lock while the delivery thread sat inside a copy holding the shared keyed mutex. The helper's D3D11 device, shared by the free-threaded frame pool, the callback and the delivery thread, wasn't multithread protected. | `SetMultithreadProtected(TRUE)` (gpuvm-sunshine a8ba3a05); a thread stuck inside a copy or lock for 5 s ends the helper so Sunshine starts a new one. 9 min without a freeze after it (before: every 1-2.5 min). |
| "You took control" without touching anything | the viewer takes the mouse and moves the pointer as its picture appears; the app read that as input and paused the agent ~4 s after every open | input in the first 4 s after the picture shows is ignored (app agent.rs) |
| square border around "Recording" | Tauri's undecorated windows keep WS_CAPTION; Windows 10 draws a 1px grey frame around a transparent one | WS_POPUP only, on every show (notch, docks, admin prompt) |
| warnings in the corner on a copy's first open | `Restart-Service`/`Stop-Service` in the guest print "Esperando a que se detenga el servicio…" as warnings, which the app shows | `-WarningAction SilentlyContinue` |

Vibeshine (the helper's origin) has the same code in its latest commit and in 2.18.9; lab 055 only ran 20 s opens,
too short to see it.

## Lessons

- A session test has to run minutes, not seconds: every lab 055 open was ~20 s and the freeze comes at 1-2.5 min.
- When a picture looks "dead", check input and picture separately: here input worked and only the picture froze.
- A few atomic stage markers plus a watchdog thread located a deadlock that reading the code didn't.
